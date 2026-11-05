#!/usr/bin/env bash
# scripts/doctor.sh: what is wrong, and which command fixes it. Read-only:
# it never changes anything, it only tells you what to run.
set -uo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
# shellcheck source=scripts/creds.sh
source "$VDNC_ROOT/scripts/creds.sh"
set +e
cd "$VDNC_ROOT"

problems=0
fine() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
fix() { # <problem> <command>
  printf '  \033[31m✗\033[0m %s\n      fix: %s\n' "$1" "$2"
  problems=$((problems + 1))
}
running() { [ "$(vdnc_container_state "$1")" = running ]; }

echo "machine"
if podman info >/dev/null 2>&1; then fine "Podman answers"; else fix "Podman does not answer" "podman machine start (ask first: it affects every lab)"; fi
vm=$(podman machine ssh date +%s 2>/dev/null | tr -d '\r' | tail -1)
if [ -n "$vm" ]; then
  skew=$(($(date +%s) - vm))
  skew=${skew#-}
  if [ "$skew" -le 5 ]; then fine "VM clock within ${skew}s"; else fix "VM clock is ${skew}s off the Mac: TTLs, schedules and backoff go wrong" "make clock-sync"; fi
fi
avail=$(df -g / | awk 'NR==2 {print $4}')
[ "${avail:-0}" -ge 10 ] && fine "Mac disk: ${avail} GiB free" || fix "Mac disk: ${avail:-?} GiB free (a full disk corrupts writes in the VM)" "free space on the Mac; then podman image prune (ask first)"
for img in "$(vdnc_conf VAULT_ENT_IMAGE)" "$(vdnc_conf OPENLDAP_IMAGE)" "$(vdnc_conf KEYCLOAK_IMAGE)"; do
  podman image exists "$img" || fix "image $img is missing" "make bootstrap (it pulls what is missing)"
done
for t in host-rocky host-ubuntu api web; do
  podman image exists "$(vdnc_conf VDNC_IMAGE_PREFIX)/$t:$(vdnc_conf VDNC_IMAGE_TAG)" ||
    fix "image $t is not built" "$([ "${t#host-}" != "$t" ] && echo "make hosts-build" || echo "make app-build")"
done
"$VDNC_ROOT/scripts/ports-check.sh" >/dev/null 2>&1 || fix "a port this lab needs is held by something else" "make ports-check, then override it in .env"

echo "vault"
[ -s .secrets/vault/vault.hclic ] || fix "no Vault Enterprise licence" "make license"
if ! running vdnc-vault-s; then
  fix "vault-s is not running: nothing can unseal or restart" "make vault-up"
else
  vault_node vault-s
  if vault_json 2>/dev/null | jq -e '.sealed' >/dev/null; then fix "vault-s is sealed: cluster nodes cannot restart" "make unseal"; else fine "vault-s unsealed"; fi
fi
up=0
for n in $VDNC_CLUSTER_NODES; do
  if ! running "vdnc-$n"; then
    fix "$n is not running" "make vault-up"
    continue
  fi
  vault_node "$n"
  if vault_json 2>/dev/null | jq -e '.sealed | not' >/dev/null; then up=$((up + 1)); else fix "$n is sealed (its seal token, or vault-s?)" "make seal-token-status; podman logs vdnc-$n | grep 403"; fi
done
[ "$up" = 3 ] && fine "three cluster nodes unsealed"
if running vdnc-vault-s; then
  "$VDNC_ROOT/scripts/seal-token-status.sh" >/dev/null 2>&1 && fine "every node's seal token accepted, more than a day left" ||
    fix "a seal token is rejected or about to expire" "make seal-token-status, then make seal-token-rotate NODE=vault-N"
fi
for t in seal-admin terraform operator; do
  [ -s ".secrets/vault/tokens/$t" ] || fix "scoped token $t is missing" "make vault-bootstrap"
done
if jq -e 'has("root_token")' .secrets/vault/seal-init.json .secrets/vault/vault-init.json 2>/dev/null | grep -q true; then
  fix "an init file still holds a root token (bootstrap did not finish)" "make vault-bootstrap"
fi
compgen -G ".secrets/vault/root-*" >/dev/null && fix "a regenerated root token is lying around" "make root-revoke CLUSTER=seal|vault"
if [ "$up" -gt 0 ]; then
  vault_cluster
  if VAULT_TOKEN=$(cat .secrets/vault/tokens/operator 2>/dev/null) vault token lookup >/dev/null 2>&1; then fine "operator token valid"; else fix "the operator token is rejected (expired after 32 days unused?)" "make root-regen CLUSTER=vault, re-run make vault-bootstrap, make root-revoke CLUSTER=vault"; fi
fi

echo "identity"
for c in vdnc-openldap vdnc-keycloak; do running "$c" || fix "$c is not running" "make identity-up"; done
if running vdnc-openldap; then
  "$VDNC_ROOT/scripts/ldap-acl.sh" --status | grep -q 'may write' &&
    [ -z "$("$VDNC_ROOT/scripts/ldap-acl.sh" --status | grep NOT)" ] && fine "LDAP rotator holds its write rule" ||
    fix "the LDAP rotator lost its write rule (scenario ldap-acl still broken?)" "make scenario-ldap-acl-heal"
fi

echo "hosts"
for d in rocky ubuntu; do
  c="vdnc-host-$d"
  if ! running "$c"; then
    fix "host-$d is not running" "make hosts-up (or make scenario-host-down-heal for host-rocky)"
    continue
  fi
  if ! podman exec "$c" id mgmt-vault >/dev/null 2>&1; then
    fix "host-$d has no managed accounts: the container was recreated" "make up (it reconfigures and re-onboards a recreated host)"
    continue
  fi
  key=$(podman exec "$c" cat /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $1" "$2}')
  [ "$key" = "$(cat ".secrets/hosts/host-$d.pub" 2>/dev/null)" ] || fix "host-$d presents another host key than Vault pinned" "make up (keyscan, tf-rotation, onboard)"
  min=$(podman exec "$c" chage -l ops-breakglass 2>/dev/null | awk -F': ' '/Minimum number of days/ {print $2}')
  [ "$min" = 0 ] || fix "host-$d: ops-breakglass has a minimum password age of $min days (scenario password-age?)" "make scenario-password-age-heal"
done

echo "rotation"
if [ "$up" -gt 0 ] && vault_active 2>/dev/null && vault_token operator 2>/dev/null; then
  listed=$(orphans)
  for id in $(cred_ids); do
    s=$(cred_state "$id" "$listed")
    case "$s" in
    missing) fix "$id is not onboarded" "make onboard" ;;
    orphaned) fix "$id is orphaned: Vault stopped rotating it" "fix the cause, then re-register it (console, or make scenario-<name>-heal)" ;;
    overdue) fix "$id is overdue: Vault is retrying (see the timeline for Vault's error)" "make rotation-status; podman logs of the active node" ;;
    esac
  done
  "$VDNC_ROOT/scripts/proof.sh" >/dev/null 2>&1 && fine "every credential logs in with Vault's password" || fix "a proof fails" "make proof"
fi

echo "app"
for c in vdnc-rotator vdnc-vault-agent vdnc-api vdnc-web; do running "$c" || fix "$c is not running" "make app-up"; done
if running vdnc-api; then
  "$VDNC_ROOT/scripts/agents-status.sh" >/dev/null 2>&1 && fine "the API's identity chain works" || fix "the API's AppRole chain is broken" "make agents-status, then make rotator-bootstrap"
fi

echo
if [ "$problems" -eq 0 ]; then echo "doctor: nothing wrong"; else echo "doctor: $problems problem(s)"; fi
[ "$problems" -eq 0 ]
