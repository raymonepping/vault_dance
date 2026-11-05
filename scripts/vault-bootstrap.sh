#!/usr/bin/env bash
# scripts/vault-bootstrap.sh: bring vault-s and the vault-1..3 cluster into
# existence. Host-side and idempotent: safe to re-run at any time.
#
# Creates only what must exist before Terraform runs: init, unseal, the
# Transit `autounseal` key, its policy and token role, one seal token per
# node, audit devices, and the scoped tokens (seal-admin, terraform,
# operator). Then it REVOKES both root tokens (D6). A re-run finds no root
# token and works with the scoped tokens; that is the normal case.
#
#   .secrets/vault/seal-init.json    vault-s unseal key (no root token after bootstrap)
#   .secrets/vault/vault-init.json   cluster recovery key (no root token after bootstrap)
#   .secrets/vault/seal/vault-N      each node's seal token (0600, written in place)
#   .secrets/vault/tokens/<name>     scoped tokens (0600)
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VDNC_ROOT"

for tool in vault jq podman openssl curl; do
  command -v "$tool" >/dev/null || {
    echo "Missing command: $tool" >&2
    exit 127
  }
done
openssl verify -CAfile vault-tls/ca-chain.pem vault-tls/vault.crt >/dev/null 2>&1 || {
  echo "vault-tls/vault.crt does not verify: run make gen-certs" >&2
  exit 1
}
[ -s .secrets/vault/vault.hclic ] || {
  echo "Vault Enterprise licence not found at .secrets/vault/vault.hclic: run make license" >&2
  exit 1
}
mkdir -p "$VDNC_STATE/seal" "$VDNC_STATE/tokens"
chmod 700 .secrets "$VDNC_STATE" "$VDNC_STATE/seal" "$VDNC_STATE/tokens"

mkdir "$VDNC_STATE/bootstrap.lock" 2>/dev/null || {
  echo "Bootstrap lock exists (.secrets/vault/bootstrap.lock). Check for a running bootstrap." >&2
  exit 1
}
trap 'rmdir "$VDNC_STATE/bootstrap.lock"' EXIT

log() { echo "[bootstrap] $*"; }
compose() { "$VDNC_ROOT/scripts/compose.sh" "$@"; }

# Four-case idempotency table: init file vs storage state.
initialize() {
  local cluster=$1 state tmp file="$VDNC_STATE/$1-init.json"
  shift
  state=$(vault_json)
  if jq -e '.initialized' <<<"$state" >/dev/null; then
    [ -s "$file" ] || {
      echo "$cluster is initialized but ${file#"$VDNC_ROOT"/} is missing. Restore from backup." >&2
      return 1
    }
    log "$cluster: already initialized"
  else
    [ ! -e "$file" ] || {
      echo "$cluster has saved keys but no initialized storage: its volume was lost. Restore the volume or move ${file#"$VDNC_ROOT"/} to .secrets/legacy/." >&2
      return 1
    }
    tmp=$(mktemp "$VDNC_STATE/$cluster-init.pending.XXXXXX")
    vault operator init -format=json "$@" >"$tmp"
    jq -e '.root_token' "$tmp" >/dev/null
    mv "$tmp" "$file"
    log "$cluster: initialized; keys saved to ${file#"$VDNC_ROOT"/}"
  fi
}

# Use the init root token while it still exists (first run, or a first run
# that stopped half way), else the named scoped token.
has_root() { jq -e 'has("root_token")' "$VDNC_STATE/$1-init.json" >/dev/null 2>&1; }
use_root() {
  VAULT_TOKEN=$(vault_init_field "$1" '.root_token')
  export VAULT_TOKEN
}

enable_audit() {
  if ! vault audit list -format=json 2>/dev/null | jq -e 'has("file/")' >/dev/null; then
    vault audit enable file file_path=/vault/audit/vault-audit.log mode=0600 >/dev/null
    log "$1: audit device enabled"
  fi
}

# A token file is "valid" when the given lookup succeeds; never printed.
write_in_place() { # <file> <value>: keep the inode (single-file bind mounts)
  : >"$1"
  chmod 600 "$1"
  printf '%s' "$2" >"$1"
}

# Scoped tokens: orphan, periodic, one policy each. No token role: a holder
# of one of these must not be able to mint more of them.
ensure_scoped_token() { # <name> <policy file>
  local name=$1 file="$VDNC_STATE/tokens/$1" t
  vault policy write "$name" "$2" >/dev/null
  if [ -s "$file" ] && VAULT_TOKEN=$(cat "$file") vault token lookup >/dev/null 2>&1; then
    return 0
  fi
  t=$(vault token create -orphan -period=768h -policy="$name" \
    -display-name="vdnc-$name" -field=token)
  write_in_place "$file" "$t"
  unset t
  log "scoped token '$name' issued (.secrets/vault/tokens/$name)"
}

revoke_root() { # <cluster>: revoke the init root token, then drop it from the file
  local cluster=$1 file="$VDNC_STATE/$1-init.json" tmp
  if [ "$cluster" = seal ]; then vault_node vault-s; else vault_cluster; fi
  use_root "$cluster"
  vault token revoke -self >/dev/null
  if vault token lookup >/dev/null 2>&1; then
    echo "$cluster: the root token still looks up after revoke; refusing to drop it from the file." >&2
    return 1
  fi
  unset VAULT_TOKEN
  tmp=$(mktemp "$VDNC_STATE/$cluster-init.pending.XXXXXX")
  jq 'del(.root_token)' "$file" >"$tmp"
  mv "$tmp" "$file"
  chmod 600 "$file"
  log "$cluster: root token revoked and removed from ${file#"$VDNC_ROOT"/}"
}

"$VDNC_ROOT/scripts/network.sh"

# ── vault-s ──────────────────────────────────────────────────────────────────
log "starting vault-s"
compose seal up -d vault-s
vault_node vault-s
vault_wait reachable
initialize seal -key-shares=1 -key-threshold=1
if vault_json | jq -e '.sealed' >/dev/null; then
  key=$(vault_init_field seal '.unseal_keys_b64[0]')
  vault operator unseal "$key" >/dev/null
  unset key
  log "seal: unsealed"
fi
vault_wait active

if has_root seal; then
  use_root seal
  if ! vault secrets list -format=json | jq -e 'has("transit/")' >/dev/null; then
    vault secrets enable transit >/dev/null
    log "seal: transit engine enabled"
  fi
  vault read transit/keys/autounseal >/dev/null 2>&1 || {
    vault write -f transit/keys/autounseal >/dev/null
    log "seal: transit key 'autounseal' created"
  }
  vault policy write autounseal vault/policies/autounseal.hcl >/dev/null
  # One periodic orphan token per node comes from this role (D5).
  vault write auth/token/roles/autounseal allowed_policies=autounseal \
    orphan=true renewable=true token_period=720h token_type=service \
    token_no_default_policy=true >/dev/null
  enable_audit seal
  ensure_scoped_token seal-admin vault/policies/seal-admin.hcl
fi
unset VAULT_TOKEN
vault_token seal-admin

# One seal token per node; reissue only a token vault-s no longer accepts.
recreate=""
for node in $VDNC_CLUSTER_NODES; do
  file="$VDNC_STATE/seal/$node"
  if [ -s "$file" ] && vault token lookup "$(cat "$file")" >/dev/null 2>&1; then
    continue
  fi
  t=$(vault token create -role=autounseal -display-name="vdnc-seal-$node" -field=token)
  write_in_place "$file" "$t"
  unset t
  recreate="$recreate $node"
  log "seal: token for $node issued (.secrets/vault/seal/$node)"
done
unset VAULT_TOKEN

# ── vault-1..3 ───────────────────────────────────────────────────────────────
start_node() { # <node>: recreate when its seal token changed, else plain up
  case " $recreate " in
  *" $1 "*) compose vault up -d --force-recreate "$1" ;;
  *) compose vault up -d "$1" ;;
  esac
}

log "starting vault-1"
start_node vault-1
vault_node vault-1
vault_wait reachable
initialize vault -recovery-shares=1 -recovery-threshold=1
vault_wait unsealed
log "vault: vault-1 unsealed"
for node in vault-2 vault-3; do
  log "starting $node (retry_join)"
  start_node "$node"
done
for node in vault-2 vault-3; do
  vault_node "$node"
  vault_wait unsealed 90
  log "vault: $node joined and unsealed"
done

vault_cluster
if has_root vault; then
  use_root vault
  enable_audit vault
  ensure_scoped_token terraform vault/policies/terraform.hcl
  ensure_scoped_token operator vault/policies/operator.hcl
  unset VAULT_TOKEN
fi

# Three voters, one leader.
vault_token operator
for _ in $(seq 1 30); do
  voters=$(vault operator raft list-peers -format=json 2>/dev/null |
    jq '[.data.config.servers[] | select(.voter)] | length' 2>/dev/null || echo 0)
  [ "$voters" = 3 ] && break
  sleep 2
done
unset VAULT_TOKEN
[ "${voters:-0}" = 3 ] || {
  echo "vault: expected 3 Raft voters, found ${voters:-0}" >&2
  exit 1
}
log "vault: 3 Raft voters"

# ── No root token survives bootstrap (D6) ─────────────────────────────────────
has_root vault && revoke_root vault
has_root seal && revoke_root seal

"$VDNC_ROOT/scripts/vault-status.sh" || true
echo 'Ready. Next: make tf-platform, make identity-up, make identity-bootstrap, make tf-identity.'
