#!/usr/bin/env bash
# scripts/rotation-status.sh: every credential as Vault describes it. Read-only.
#
# STATE is derived from Vault's own fields, because 2.2.1 keeps an orphan
# record in sys/rotation/orphans after the credential was re-registered and
# rotates again (prompt 05):
#   ok          next rotation in the future
#   overdue     next rotation in the past, not listed: Vault is retrying
#   ORPHANED    next rotation in the past and listed in sys/rotation/orphans
#   recovered   listed, but rotating on time again (stale orphan record)
#   on read     rotate-on-read only, no schedule
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
# shellcheck source=scripts/creds.sh
source "$VDNC_ROOT/scripts/creds.sh"

vault_active
vault_token operator
listed=$(orphans)
GRACE=15 # a due rotation can take a few seconds to run
now=$(date -u +%s)
epoch() { [ -n "$1" ] && [ "$1" != null ] && date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${1%.*}Z" +%s 2>/dev/null || echo ""; }
ago() { [ -n "$1" ] && echo "$(($2 - $1))s" || echo -; }
printf '%-27s %-15s %-11s %-14s %-9s %-9s %s\n' CREDENTIAL MODE POLICY SCHEDULE LAST NEXT STATE
for id in $(cred_ids); do
  if ! c=$(vault read -format=json "$(cred_config_path "$id")" 2>/dev/null); then
    printf '%-27s %-15s %s\n' "$id" "$(cred "$id" mode)" "not onboarded (make onboard)"
    continue
  fi
  policy=$(jq -r '.data.rotation_policy | if . == "" or . == null then "default" else . end' <<<"$c")
  sched=$(jq -r '.data | if (.rotation_schedule // "") != "" then .rotation_schedule elif (.rotation_period // 0) > 0 then "every \(.rotation_period)s" elif .rotate_on_read then "on read" else "manual" end' <<<"$c")
  last=$(epoch "$(jq -r '.data.last_vault_rotation // empty' <<<"$c")")
  next=$(epoch "$(jq -r '.data.next_vault_rotation // empty' <<<"$c")")
  rid=$(cred_rotation_id "$id")
  in_list=no
  grep -qxF "$rid" <<<"$listed" && in_list=yes
  if [ "$sched" = "on read" ]; then
    state="on read"
  elif [ -n "$next" ] && [ "$next" -gt $((now - GRACE)) ]; then
    [ "$in_list" = yes ] && state="recovered (stale orphan record)" || state=ok
  else
    [ "$in_list" = yes ] && state=ORPHANED || state="overdue (Vault is retrying)"
  fi
  printf '%-27s %-15s %-11s %-14s %-9s %-9s %s\n' "$id" "$(cred "$id" mode)" "$policy" "$sched" \
    "$(ago "$last" "$now")" "$([ -n "$next" ] && echo "in $((next - now))s" || echo -)" "$state"
done
