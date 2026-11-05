#!/usr/bin/env bash
# scripts/common.sh: shared, host-side helpers. Source, do not execute.
#
# Host tooling talks to the Vault nodes on their published loopback ports and
# verifies TLS against the lab CA; nothing here uses -tls-skip-verify.
# No helper here uses a root token: after bootstrap there is none (D6).
set -euo pipefail
umask 077
VDNC_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VDNC_STATE="$VDNC_ROOT/.secrets/vault"
export VAULT_CACERT="$VDNC_ROOT/vault-tls/ca-chain.pem"
unset VAULT_SKIP_VERIFY VAULT_NAMESPACE VAULT_TOKEN VAULT_TLS_SERVER_NAME

VDNC_CLUSTER_NODES="vault-1 vault-2 vault-3"

# Effective config value: .env overrides config/defaults.conf.
vdnc_conf() {
  local name=$1 v=""
  [ -f "$VDNC_ROOT/.env" ] && v=$(grep -E "^${name}=" "$VDNC_ROOT/.env" | tail -1 | cut -d= -f2- || true)
  [ -n "$v" ] || v=$(grep -E "^${name}=" "$VDNC_ROOT/config/defaults.conf" | tail -1 | cut -d= -f2- || true)
  printf '%s' "$v"
}

# Cluster a node belongs to: "seal" (vault-s) or "vault" (vault-1..3).
vault_cluster_of() {
  case "$1" in
  vault-s) echo seal ;;
  vault-1 | vault-2 | vault-3) echo vault ;;
  *)
    echo "Unknown Vault node: $1" >&2
    return 1
    ;;
  esac
}

vault_container() { printf 'vdnc-%s' "$1"; }

vault_port_of() {
  case "$1" in
  vault-s) vdnc_conf VDNC_PORT_VAULT_S ;;
  vault-1) vdnc_conf VDNC_PORT_VAULT_1 ;;
  vault-2) vdnc_conf VDNC_PORT_VAULT_2 ;;
  vault-3) vdnc_conf VDNC_PORT_VAULT_3 ;;
  *)
    echo "Unknown Vault node: $1" >&2
    return 1
    ;;
  esac
}

# Point VAULT_ADDR at one node's published port.
vault_node() {
  local port
  port=$(vault_port_of "$1")
  VAULT_ADDR="https://127.0.0.1:$port"
  export VAULT_ADDR
}

# Point VAULT_ADDR at the cluster: the first node that answers unsealed.
# Standbys forward requests to the active node, so any unsealed node works.
vault_cluster() {
  local n
  for n in $VDNC_CLUSTER_NODES; do
    vault_node "$n"
    if vault_json 2>/dev/null | jq -e '.initialized and (.sealed | not)' >/dev/null 2>&1; then
      return 0
    fi
  done
  vault_node vault-1
}

# Point VAULT_ADDR at the active node. Needed for the rotation manager:
# sys/rotation/orphans answers only there (a performance standby says
# "rotation manager is not initialized").
vault_active() {
  local n
  for n in $VDNC_CLUSTER_NODES; do
    vault_node "$n"
    if curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -e '.is_self' >/dev/null 2>&1; then
      return 0
    fi
  done
  echo "No active node in vault-1..3." >&2
  return 1
}

# `vault status` exits 2 when sealed; that is still a valid answer.
vault_json() {
  local code=0
  vault status -format=json || code=$?
  [ "$code" -eq 0 ] || [ "$code" -eq 2 ]
}

# vault_wait reachable|unsealed|active [attempts]
vault_wait() {
  local mode=$1 max=${2:-60} attempt state
  for ((attempt = 0; attempt < max; attempt++)); do
    if state=$(vault_json 2>/dev/null); then
      case "$mode" in
      reachable) return 0 ;;
      unsealed) jq -e '.initialized and (.sealed | not)' <<<"$state" >/dev/null && return 0 ;;
      active) jq -e '.initialized and (.sealed | not)' <<<"$state" >/dev/null &&
        curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -e '.is_self' >/dev/null && return 0 ;;
      esac
    fi
    sleep 2
  done
  echo "Timed out waiting for $VAULT_ADDR ($mode)." >&2
  return 1
}

# Read one field from .secrets/vault/<cluster>-init.json.
vault_init_field() {
  jq -er "$2" "$VDNC_STATE/$1-init.json"
}

# Export a scoped token (D7): seal-admin, terraform or operator.
vault_token() {
  local file="$VDNC_STATE/tokens/$1"
  [ -s "$file" ] || {
    echo "Scoped token '$1' not found at ${file#"$VDNC_ROOT"/}. Run make vault-bootstrap." >&2
    return 1
  }
  VAULT_TOKEN=$(cat "$file")
  export VAULT_TOKEN
  # Periodic tokens live as long as they are used: renew on every use (best
  # effort; it fails harmlessly when VAULT_ADDR points at the other cluster).
  vault token renew >/dev/null 2>&1 || true
}

# The first 8 hex characters of SHA-256: how this lab shows a secret.
fingerprint() {
  printf '%s' "$1" | shasum -a 256 | cut -c1-8
}

vdnc_container_state() {
  podman container inspect "$1" --format '{{.State.Status}}' 2>/dev/null || echo "not created"
}

# `vault list` on an empty path prints [] *and* exits 2: always one JSON array.
vault_list_json() {
  local o
  o=$(vault list -format=json "$1" 2>/dev/null) || true
  jq -c 'if type == "array" then . else [] end' <<<"${o:-[]}" 2>/dev/null || echo '[]'
}
