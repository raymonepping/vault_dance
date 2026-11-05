#!/usr/bin/env bash
# scripts/scenario.sh <host-down|ldap-acl|password-age> <break|heal|status>
#
# The failure stories of docs/PRD.md (FR-18 to FR-20), each broken precisely:
#
#   host-down     host-rocky stops. Its three accounts cannot rotate; Vault
#                 retries with growing backoff (an OS account does not follow
#                 its rotation policy on 2.2.1, so it is never orphaned).
#                 heal: start the host; the password Vault holds still logs
#                 in, and Vault's next retry rotates it.
#   ldap-acl      cn=vault-rotator loses its write rule on service-account
#                 passwords (only that clause). Root-managed roles fail;
#                 svc-billing (quick-step, 2 x 2) is orphaned within minutes.
#                 People still sign in: their bind is untouched.
#                 heal: restore the rule, re-register svc-billing.
#   password-age  ops-breakglass on host-ubuntu (self-managed, quick-step)
#                 gets a minimum password age of 2 days: passwd refuses to
#                 change it again. Vault retries. heal: minimum back to 0.
#
# status prints the affected credentials' state. Operator token.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
# shellcheck source=scripts/creds.sh
source "$VDNC_ROOT/scripts/creds.sh"
cd "$VDNC_ROOT"

name=${1:?Usage: scenario.sh <host-down|ldap-acl|password-age> <break|heal|status>}
action=${2:?Usage: scenario.sh <host-down|ldap-acl|password-age> <break|heal|status>}

case "$name" in
host-down) affected="host-rocky/mgmt-vault host-rocky/app-deploy host-rocky/ops-breakglass" ;;
ldap-acl) affected="ldap/svc-billing ldap/svc-batch" ;;
password-age) affected="host-ubuntu/ops-breakglass" ;;
*)
  echo "scenario: unknown scenario '$name' (host-down, ldap-acl, password-age)" >&2
  exit 64
  ;;
esac

status() {
  local listed id
  vault_active
  vault_token operator
  listed=$(orphans)
  for id in $affected; do
    printf '  %-28s %-10s %s\n' "$id" "$(cred_state "$id" "$listed")" "$(cred_mark "$id")"
  done
}

reregister() { # <id>: write the stored configuration again (the documented restore)
  local id=$1 cfg args=()
  vault_active
  vault_token operator
  cfg=$(vault read -format=json "$(cred_config_path "$id")")
  while IFS= read -r a; do args+=("$a"); done < <(jq -r '.data | to_entries[]
    | select(.key | IN("rotation_period","rotation_schedule","rotation_window","rotation_policy","username","dn","parent_account_ref","rotate_on_read","rotate_on_read_cooldown"))
    | select(.value != null and .value != "" and .value != 0 and .value != false)
    | "\(.key)=\(.value)"' <<<"$cfg")
  vault write "$(cred_config_path "$id")" "${args[@]}" >/dev/null
  echo "scenario: $id re-registered (${#args[@]} stored fields written again)"
}

case "$name/$action" in
*/status) ;;
host-down/break)
  podman stop -t 5 vdnc-host-rocky >/dev/null
  echo "scenario host-down: host-rocky is stopped; Vault will retry its accounts with backoff"
  ;;
host-down/heal)
  podman start vdnc-host-rocky >/dev/null
  for _ in $(seq 1 30); do
    [ "$(podman inspect vdnc-host-rocky --format '{{.State.Health.Status}}')" = healthy ] && break
    sleep 2
  done
  echo "scenario host-down: host-rocky is back; Vault's next retry will rotate its accounts"
  ;;
ldap-acl/break)
  "$VDNC_ROOT/scripts/ldap-acl.sh" --break-rotator
  ;;
ldap-acl/heal)
  "$VDNC_ROOT/scripts/ldap-acl.sh" --heal
  reregister ldap/svc-billing
  ;;
password-age/break)
  "$VDNC_ROOT/scripts/ansible.sh" scenario.yml -e target_host=host-ubuntu -e account=ops-breakglass -e min_days=2 |
    grep -E '^host-ubuntu .*failed=0' >/dev/null
  echo "scenario password-age: ops-breakglass on host-ubuntu may not change its password for 2 days; passwd will refuse"
  ;;
password-age/heal)
  "$VDNC_ROOT/scripts/ansible.sh" scenario.yml -e target_host=host-ubuntu -e account=ops-breakglass -e min_days=0 |
    grep -E '^host-ubuntu .*failed=0' >/dev/null
  echo "scenario password-age: minimum password age back to 0; Vault's next retry will rotate it"
  ;;
*)
  echo "scenario: unknown action '$action' (break, heal, status)" >&2
  exit 64
  ;;
esac
echo "affected:"
status
