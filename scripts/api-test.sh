#!/usr/bin/env bash
# scripts/api-test.sh: every API route against the live stack, as each
# persona (Keycloak access tokens from the lab-only dance-cli client, sent as
# Bearer tokens; Vault decides). Checks status and shape, the refusals, and
# that no answer ever contains a password field.
#
# Changes state on purpose: rotates svc-billing and app-deploy once, checks
# out svc-reports (which rotates it) and re-registers app-deploy.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VDNC_ROOT"

API="http://127.0.0.1:$(vdnc_conf VDNC_PORT_API)"
KC="http://localhost:$(vdnc_conf VDNC_PORT_KEYCLOAK)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0
ok() {
  printf '  \033[32m✓\033[0m %s\n' "$*"
  pass=$((pass + 1))
}
bad() {
  printf '  \033[31m✗\033[0m %s\n' "$*"
  fail=$((fail + 1))
}

token() { # <persona> -> Keycloak access token on stdout
  "$VDNC_ROOT/scripts/identity-secrets.sh" --print "$1" | tr -d '\n' |
    curl -sf "$KC/realms/dance/protocol/openid-connect/token" \
      -d grant_type=password -d client_id=dance-cli -d scope=openid \
      --data-urlencode "username=$1" --data-urlencode "password@-" | jq -r '.access_token'
}

# req <label> <expected status> <method> <path> [persona] [jq assertion]
req() {
  local label=$1 want=$2 method=$3 path=$4 who=${5:-} assert=${6:-} code auth=()
  [ -z "$who" ] || auth=(-H "Authorization: Bearer ${TOKENS[$who]}")
  code=$(curl -s -o "$TMP/body" -w '%{http_code}' -X "$method" "${auth[@]}" "$API$path" || echo 000)
  if [ "$code" != "$want" ]; then
    bad "$label: HTTP $code, expected $want ($(jq -r '.error // empty' "$TMP/body" 2>/dev/null | cut -c1-140))"
    return
  fi
  if jq -e '[.. | objects | keys[] | select(. == "password" or . == "last_password")] | length > 0' "$TMP/body" >/dev/null 2>&1; then
    bad "$label: the answer contains a password field"
    return
  fi
  if [ -n "$assert" ] && ! jq -e "$assert" "$TMP/body" >/dev/null 2>&1; then
    bad "$label: HTTP $code but '$assert' does not hold"
    return
  fi
  ok "$label (HTTP $code)"
}

declare -A TOKENS
for p in tess otto ada; do TOKENS[$p]=$(token "$p"); done

echo "platform routes (the API's own identity)"
req "health" 200 GET /api/health "" '.ok and .agent.tokenPresent and (.nodes | length == 3)'
req "health: Vault's log files are readable" 200 GET /api/health "" '[.vaultLogs[] | select(.file)] | length == 3'
req "cluster: three voters, one active node, licence" 200 GET /api/cluster "" '([.raft[] | select(.voter)] | length == 3) and ([.nodes[] | select(.active)] | length == 1) and .license.expirationTime'
req "credentials: ten, each with a state" 200 GET /api/credentials "" '(.credentials | length == 10) and all(.credentials[]; .state)'
req "credentials: none orphaned or overdue" 200 GET /api/credentials "" 'all(.credentials[]; .state != "orphaned" and .state != "overdue")'
req "credential: OS account with versions" 200 GET '/api/credential?id=host-rocky/app-deploy' "" '.versions.current_version >= 1 and .credential.mode == "parent-managed"'
req "credential: LDAP role with a health-check result" 200 GET '/api/credential?id=ldap/svc-billing' "" '.credential.engine == "ldap" and .versions == null'
req "credential: unknown id refused" 400 GET '/api/credential?id=host-rocky/root'
req "credential: path traversal refused" 400 GET '/api/credential?id=host-rocky/..%2Fx'
for id in host-rocky/app-deploy host-ubuntu/ops-breakglass ldap/svc-batch ldap-self/svc-backup; do
  req "proof $id: PASS with a fingerprint" 200 POST "/api/credential/proof?id=$id" "" '.proof.ok and (.proof.fingerprint | test("^[0-9a-f]{8}$"))'
done
req "proof svc-reports refused (reading it rotates it)" 409 POST '/api/credential/proof?id=ldap/svc-reports'
req "policies: default and quick-step" 200 GET /api/policies "" '[.policies[].name] | index("default") != null and index("quick-step") != null'
req "orphans: Vault's list" 200 GET /api/orphans "" '.orphans | type == "array"'
req "timeline" 200 GET '/api/timeline?limit=5' "" '.events | type == "array"'
req "me: signed out" 200 GET /api/me "" '.signedIn == false'
req "an action without a person is refused" 401 POST '/api/credential/rotate?id=ldap/svc-billing'

echo "tess (viewer)"
req "tess: me" 200 GET /api/me tess '.signedIn and (.policies | index("dance-viewer") != null) and (.actions["os.rotate"].allowed | not)'
req "tess: rotate refused by Vault" 403 POST '/api/credential/rotate?id=host-rocky/app-deploy' tess
req "tess: check out refused by Vault" 403 POST '/api/credential/checkout?id=ldap/svc-reports' tess
req "tess: re-register refused by Vault" 403 POST '/api/credential/reregister?id=host-rocky/app-deploy' tess
req "tess: health check refused by Vault" 403 POST '/api/credential/health-check?id=ldap/svc-billing' tess

echo "otto (operator)"
req "otto: me" 200 GET /api/me otto '.actions["os.rotate"].allowed and .actions["ldap.checkout"].allowed and (.actions["policy.edit"].allowed | not)'
req "otto: rotate svc-billing" 200 POST '/api/credential/rotate?id=ldap/svc-billing' otto '.rotated'
req "otto: rotate app-deploy (parent-managed)" 200 POST '/api/credential/rotate?id=host-rocky/app-deploy' otto '.rotated'
req "otto: proof after his rotation" 200 POST '/api/credential/proof?id=host-rocky/app-deploy' "" '.proof.ok'
req "otto: health check svc-billing" 200 POST '/api/credential/health-check?id=ldap/svc-billing' otto '.result.healthy'
req "otto: check out svc-reports (rotates on read)" 200 POST '/api/credential/checkout?id=ldap/svc-reports' otto '.proof.ok and (.checkout.fingerprint | test("^[0-9a-f]{8}$"))'
cp "$TMP/body" "$TMP/first"
req "otto: second check-out inside the cooldown" 200 POST '/api/credential/checkout?id=ldap/svc-reports' otto '.checkout.rotatedOnRead == false'
if [ "$(jq -r .checkout.fingerprint "$TMP/first")" = "$(jq -r .checkout.fingerprint "$TMP/body")" ]; then
  ok "otto: same fingerprint inside the cooldown"
else
  bad "otto: the fingerprint changed inside the cooldown"
fi
req "otto: check out break-glass (OS)" 200 POST '/api/credential/checkout?id=host-ubuntu/ops-breakglass' otto '.proof.ok'
req "otto: re-register app-deploy (writes its stored config)" 200 POST '/api/credential/reregister?id=host-rocky/app-deploy' otto '.reregistered and (.wrote | index("rotation_policy") != null)'
req "otto: re-register svc-billing" 200 POST '/api/credential/reregister?id=ldap/svc-billing' otto '.reregistered'
req "otto: unlock refused by Vault (Active Directory only)" 400 POST '/api/credential/unlock?id=ldap/svc-billing' otto '.error | test("not supported")'

echo "ada (admin)"
req "ada: me" 200 GET /api/me ada '.actions["policy.edit"].allowed and (.policies | index("dance-admin") != null)'
req "ada: timeline shows otto's actions" 200 GET '/api/timeline?kind=rotate' "" '[.events[] | select(.by == "otto")] | length >= 2'

echo
echo "api-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
