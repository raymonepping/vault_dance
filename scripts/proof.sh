#!/usr/bin/env bash
# scripts/proof.sh [id...]: log in with every credential Vault holds right now.
#
#   os    SSH to the host as the account with Vault's current password
#         (sshpass from a file descriptor, host key from known_hosts)
#   ldap  a simple bind as the entry inside the openldap container
#
# Prints PASS or FAIL and a fingerprint (first 8 hex of SHA-256), never the
# password. Rotate-on-read roles (svc-reports) are skipped: reading their
# secret rotates them. CHECKOUT=1 reads (and so rotates) them too.
# Exit 1 when any proof fails. Operator token.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
# shellcheck source=scripts/creds.sh
source "$VDNC_ROOT/scripts/creds.sh"
cd "$VDNC_ROOT"

ids=${*:-$(cred_ids)}
vault_active
vault_token operator
bad=0
printf '%-28s %-15s %-8s %-9s %s\n' CREDENTIAL MODE VERSION SECRET PROOF
for id in $ids; do
  if [ "$(cred "$id" rotate_on_read)" = true ] && [ "${CHECKOUT:-}" != 1 ]; then
    printf '%-28s %-15s %-8s %-9s %s\n' "$id" "$(cred "$id" mode)" - - "skipped (rotate on read; CHECKOUT=1 to check out)"
    continue
  fi
  if ! s=$(vault read -format=json "$(cred_secret_path "$id")" 2>/dev/null); then
    printf '%-28s %-15s %-8s %-9s %s\n' "$id" "$(cred "$id" mode)" - - "FAIL (Vault has no such credential: make onboard)"
    bad=1
    continue
  fi
  pw=$(jq -r '.data.password' <<<"$s")
  ver=$(jq -r '.data.version // .data.password_version // "-"' <<<"$s")
  fp=$(fingerprint "$pw")
  case "$(cred "$id" engine)" in
  os) res=$(printf '%s\n' "$pw" | ssh_login "$(cred "$id" host)" "$(cred "$id" account)" || true) ;;
  ldap) res=$(printf '%s' "$pw" | ldap_bind "$(cred_dn "$id")" || true) ;;
  esac
  unset pw s
  [ "$res" = PASS ] || bad=1
  printf '%-28s %-15s %-8s %-9s %s\n' "$id" "$(cred "$id" mode)" "$ver" "$fp" "$res"
done
exit "$bad"
