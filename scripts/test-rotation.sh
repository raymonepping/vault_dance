#!/usr/bin/env bash
# scripts/test-rotation.sh [scenario...]: every failure story end to end
# (make rotation-test). Each case must break the way Vault says it does and
# heal; waits are on Vault's state, bounded, never fixed sleeps.
#
#   host-down     proofs PASS → stop host-rocky → app-deploy overdue, Vault's
#                 log has the failure → start → the old password still logs
#                 in → Vault's next retry rotates it → proof PASS
#   ldap-acl      → rotator loses write → svc-billing orphaned (2 x 2) while
#                 tess and ada still sign in (LDAP and Keycloak) → heal and
#                 re-register → rotated again → proof PASS
#   password-age  → minimum age 2 days → ops-breakglass@host-ubuntu overdue,
#                 the failure names passwd → minimum 0 → rotated → PASS
#
# Then every credential is proved. Changes state on purpose; takes up to
# about 25 minutes. Operator token.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
# shellcheck source=scripts/creds.sh
source "$VDNC_ROOT/scripts/creds.sh"
cd "$VDNC_ROOT"

API="http://127.0.0.1:$(vdnc_conf VDNC_PORT_API)"
KC="http://localhost:$(vdnc_conf VDNC_PORT_KEYCLOAK)"
RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT
fail=0

say() { printf '[rotation-test %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
result() { # <scenario> <step> <ok|FAIL> <detail>
  printf '%-13s %-44s %-5s %s\n' "$1" "$2" "$3" "$4" >>"$RESULTS"
  [ "$3" = ok ] || fail=1
  say "$1: $2: $3 $4"
}

state() {
  vault_active >/dev/null
  vault_token operator >/dev/null
  cred_state "$1" "$(orphans)"
}
mark() {
  vault_active >/dev/null
  vault_token operator >/dev/null
  cred_mark "$1"
}
prove() { "$VDNC_ROOT/scripts/proof.sh" "$@" >/dev/null 2>&1; }

# wait_for <seconds> <description> <command...>: poll every 5s until the
# command succeeds; prints how long it took.
wait_for() {
  local max=$1 what=$2 t0 now
  shift 2
  t0=$(date +%s)
  while :; do
    if "$@" >/dev/null 2>&1; then
      echo "$(($(date +%s) - t0))s"
      return 0
    fi
    now=$(date +%s)
    [ $((now - t0)) -lt "$max" ] || {
      echo "not within ${max}s ($what)"
      return 1
    }
    sleep 5
  done
}
is_state() { case " $2 " in *" $(state "$1") "*) return 0 ;; esac; return 1; }
moved() { [ "$(mark "$1")" != "$2" ]; }
api_failure() { curl -sf "$API/api/timeline?kind=failure&id=$1&limit=50" | jq -e --arg p "$2" '[.events[] | select(.detail | test($p; "i"))] | length > 0'; }
ldap_login() { # <persona>: Vault LDAP auth still works
  "$VDNC_ROOT/scripts/identity-secrets.sh" --print "$1" | tr -d '\n' |
    vault write -format=json "auth/ldap/login/$1" password=- | jq -e '.auth.client_token' >/dev/null
}
kc_login() { # <persona>: Keycloak (federated to the same directory) still works
  "$VDNC_ROOT/scripts/identity-secrets.sh" --print "$1" | tr -d '\n' |
    curl -sf "$KC/realms/dance/protocol/openid-connect/token" -d grant_type=password -d client_id=dance-cli \
      -d scope=openid --data-urlencode "username=$1" --data-urlencode "password@-" | jq -e '.access_token' >/dev/null
}

"$VDNC_ROOT/scripts/clock-sync.sh" >/dev/null

case_host_down() {
  local id=host-rocky/app-deploy m r
  prove "$id" && result host-down "baseline proof" ok "" || result host-down "baseline proof" FAIL ""
  m=$(mark "$id")
  "$VDNC_ROOT/scripts/scenario.sh" host-down break >/dev/null
  if r=$(wait_for 300 "overdue" is_state "$id" "overdue orphaned"); then result host-down "app-deploy overdue (Vault retrying)" ok "$r"; else result host-down "app-deploy overdue (Vault retrying)" FAIL "$r"; fi
  if r=$(wait_for 120 "failure on the timeline" api_failure "$id" "host-rocky"); then result host-down "Vault's failure line on the API timeline" ok "$r"; else result host-down "Vault's failure line on the API timeline" FAIL "$r"; fi
  [ "$(mark "$id")" = "$m" ] && result host-down "no rotation while the host is down" ok "" || result host-down "no rotation while the host is down" FAIL "version moved"
  "$VDNC_ROOT/scripts/scenario.sh" host-down heal >/dev/null
  if prove "$id"; then result host-down "the held password still logs in (no lockout)" ok ""; else result host-down "the held password still logs in (no lockout)" FAIL ""; fi
  if r=$(wait_for 420 "rotated again" moved "$id" "$m"); then result host-down "Vault's next retry rotated it" ok "$r"; else result host-down "Vault's next retry rotated it" FAIL "$r"; fi
  if r=$(wait_for 60 "proof" prove host-rocky/mgmt-vault host-rocky/app-deploy host-rocky/ops-breakglass); then result host-down "every host-rocky account proved" ok "$r"; else result host-down "every host-rocky account proved" FAIL "$r"; fi
}

case_ldap_acl() {
  local id=ldap/svc-billing m r
  prove "$id" && result ldap-acl "baseline proof" ok "" || result ldap-acl "baseline proof" FAIL ""
  "$VDNC_ROOT/scripts/scenario.sh" ldap-acl break >/dev/null
  if r=$(wait_for 600 "orphaned" is_state "$id" "orphaned"); then result ldap-acl "svc-billing orphaned (2 x 2)" ok "$r"; else result ldap-acl "svc-billing orphaned (2 x 2)" FAIL "$r"; fi
  if r=$(wait_for 60 "failure on the timeline" api_failure "$id" "Insufficient Access"); then result ldap-acl "Vault's failure line on the API timeline" ok "$r"; else result ldap-acl "Vault's failure line on the API timeline" FAIL "$r"; fi
  vault_active >/dev/null
  if ldap_login tess && ldap_login ada; then result ldap-acl "people still sign in (Vault LDAP auth)" ok ""; else result ldap-acl "people still sign in (Vault LDAP auth)" FAIL ""; fi
  if kc_login tess && kc_login ada; then result ldap-acl "people still sign in (Keycloak)" ok ""; else result ldap-acl "people still sign in (Keycloak)" FAIL ""; fi
  if prove "$id"; then result ldap-acl "the held password still binds (no lockout)" ok ""; else result ldap-acl "the held password still binds (no lockout)" FAIL ""; fi
  m=$(mark "$id")
  "$VDNC_ROOT/scripts/scenario.sh" ldap-acl heal >/dev/null
  if r=$(wait_for 180 "rotated again" moved "$id" "$m"); then result ldap-acl "re-registered: rotated again" ok "$r"; else result ldap-acl "re-registered: rotated again" FAIL "$r"; fi
  if r=$(wait_for 60 "on time" is_state "$id" "ok recovered"); then result ldap-acl "on schedule again (Vault keeps the record)" ok "$r"; else result ldap-acl "on schedule again (Vault keeps the record)" FAIL "$r"; fi
  if r=$(wait_for 420 "svc-batch on time" is_state ldap/svc-batch "ok recovered"); then result ldap-acl "svc-batch (default policy) healed by itself" ok "$r"; else result ldap-acl "svc-batch (default policy) healed by itself" FAIL "$r"; fi
  if r=$(wait_for 60 "proof" prove ldap/svc-billing ldap/svc-batch); then result ldap-acl "svc-billing and svc-batch proved" ok "$r"; else result ldap-acl "svc-billing and svc-batch proved" FAIL "$r"; fi
}

case_password_age() {
  local id=host-ubuntu/ops-breakglass m r
  prove "$id" && result password-age "baseline proof" ok "" || result password-age "baseline proof" FAIL ""
  m=$(mark "$id")
  "$VDNC_ROOT/scripts/scenario.sh" password-age break >/dev/null
  if r=$(wait_for 300 "overdue" is_state "$id" "overdue orphaned"); then result password-age "ops-breakglass overdue (passwd refuses)" ok "$r"; else result password-age "ops-breakglass overdue (passwd refuses)" FAIL "$r"; fi
  if r=$(wait_for 120 "failure on the timeline" api_failure "$id" "wait longer|password"); then result password-age "Vault's failure line on the API timeline" ok "$r"; else result password-age "Vault's failure line on the API timeline" FAIL "$r"; fi
  if prove "$id"; then result password-age "the held password still logs in (no lockout)" ok ""; else result password-age "the held password still logs in (no lockout)" FAIL ""; fi
  "$VDNC_ROOT/scripts/scenario.sh" password-age heal >/dev/null
  if r=$(wait_for 420 "rotated again" moved "$id" "$m"); then result password-age "Vault's next retry rotated it" ok "$r"; else result password-age "Vault's next retry rotated it" FAIL "$r"; fi
  if r=$(wait_for 60 "proof" prove "$id"); then result password-age "proved" ok "$r"; else result password-age "proved" FAIL "$r"; fi
}

scenarios=${*:-host-down ldap-acl password-age}
for s in $scenarios; do
  say "── $s"
  case $s in
  host-down) case_host_down ;;
  ldap-acl) case_ldap_acl ;;
  password-age) case_password_age ;;
  *)
    echo "rotation-test: unknown scenario $s" >&2
    exit 64
    ;;
  esac
done

if r=$(wait_for 300 "all proofs" prove); then result all "every credential proved" ok "$r"; else result all "every credential proved" FAIL "$r"; fi

echo
printf '%-13s %-44s %-5s %s\n' SCENARIO STEP RESULT TOOK
cat "$RESULTS"
exit "$fail"
