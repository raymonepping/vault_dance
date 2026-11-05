#!/usr/bin/env bash
# scripts/identity-verify.sh: every persona and system bind.
#
#   people   LDAP login and Keycloak (JWT) login give the same Vault policies;
#            a viewer is refused an operator path, an operator an admin path
#   binds    the directory's ACLs, asked with slapacl (changes nothing):
#            vault-auth-bind reads and cannot write; vault-rotator writes
#            service-account passwords and not people's
#
# Passwords come from Vault KV through stdin or variables; nothing is printed.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VDNC_ROOT"

B="dc=dance,dc=lab"
KC="http://localhost:$(vdnc_conf VDNC_PORT_KEYCLOAK)"
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
expect() { # <msg> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

declare_policies() {
  case "$1" in
  tess) echo "dance-viewer" ;;
  otto) echo "dance-operator,dance-viewer" ;;
  ada) echo "dance-admin,dance-operator,dance-viewer" ;;
  esac
}

vault_cluster
caps() { # <token> <path>
  VAULT_TOKEN=$1 vault token capabilities "$2" 2>/dev/null | tr -d ' '
}
can() { # <token> <path> <capability>
  case ",$(caps "$1" "$2")," in *",$3,"* | *",root,"*) echo yes ;; *) echo no ;; esac
}

echo "people"
for u in tess otto ada; do
  pw=$("$VDNC_ROOT/scripts/identity-secrets.sh" --print "$u")
  want=$(declare_policies "$u")

  ldap=$(printf '%s' "$pw" | vault write -format=json "auth/ldap/login/$u" password=- 2>/dev/null || echo '{}')
  lt=$(jq -r '.auth.client_token // empty' <<<"$ldap")
  got=$(jq -r '[.auth.policies[]? | select(startswith("dance-"))] | sort | join(",")' <<<"$ldap")
  expect "$u: LDAP login gives $want" "$want" "$got"

  at=$(printf '%s' "$pw" | curl -sf "$KC/realms/dance/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=dance-cli -d scope=openid \
    --data-urlencode "username=$u" --data-urlencode "password@-" | jq -r '.access_token // empty' || true)
  unset pw
  jt=""
  if [ -n "$at" ]; then
    jwt=$(vault write -format=json auth/jwt/login role=console jwt="$at" 2>/dev/null || echo '{}')
    jt=$(jq -r '.auth.client_token // empty' <<<"$jwt")
    got=$(jq -r '[.auth.identity_policies[]? | select(startswith("dance-"))] | sort | join(",")' <<<"$jwt")
  else
    got="(no Keycloak token)"
  fi
  unset at
  expect "$u: Keycloak + JWT login gives $want" "$want" "$got"

  if [ -n "$lt" ]; then
    case "$u" in
    tess)
      expect "tess cannot rotate a Linux account" no "$(can "$lt" os/hosts/host-rocky/accounts/app-deploy/rotate update)"
      expect "tess cannot read a password" no "$(can "$lt" os/hosts/host-rocky/accounts/app-deploy/creds read)"
      expect "tess can list orphans" yes "$(can "$lt" sys/rotation/orphans read)"
      ;;
    otto)
      expect "otto can rotate a Linux account" yes "$(can "$lt" os/hosts/host-rocky/accounts/app-deploy/rotate update)"
      expect "otto can check out svc-reports" yes "$(can "$lt" ldap/static-cred/svc-reports read)"
      expect "otto cannot change a rotation policy" no "$(can "$lt" sys/policies/rotation/quick-step update)"
      ;;
    ada)
      expect "ada can change a rotation policy" yes "$(can "$lt" sys/policies/rotation/quick-step update)"
      expect "ada cannot write an ACL policy" no "$(can "$lt" sys/policies/acl/dance-admin update)"
      ;;
    esac
    [ -z "$jt" ] || expect "$u: JWT token has the same authority on rotate" \
      "$(can "$lt" os/hosts/host-rocky/accounts/app-deploy/rotate update)" \
      "$(can "$jt" os/hosts/host-rocky/accounts/app-deploy/rotate update)"
    VAULT_TOKEN=$lt vault token revoke -self >/dev/null 2>&1 || true
  fi
  [ -z "$jt" ] || VAULT_TOKEN=$jt vault token revoke -self >/dev/null 2>&1 || true
done

echo "directory ACLs (slapacl, no changes)"
acl() { # <bind dn> <entry dn> <attr/access>: "allowed" or "DENIED"
  # slapacl exits 0 either way; its last line says ALLOWED or DENIED.
  case "$(podman exec vdnc-openldap slapacl -F /etc/ldap/slapd.d -D "$1" -b "$2" "$3" 2>&1 | tail -1)" in
  *": ALLOWED") echo allowed ;;
  *) echo DENIED ;;
  esac
}
auth="cn=vault-auth-bind,ou=system,$B"
rot="cn=vault-rotator,ou=system,$B"
expect "vault-auth-bind reads people" allowed "$(acl "$auth" "uid=tess,ou=people,$B" cn/read)"
expect "vault-auth-bind reads groups" allowed "$(acl "$auth" "cn=dance-viewers,ou=groups,$B" member/read)"
expect "vault-auth-bind cannot write a service-account password" DENIED "$(acl "$auth" "cn=svc-billing,ou=service-accounts,$B" userPassword/write)"
expect "vault-auth-bind cannot read a password" DENIED "$(acl "$auth" "uid=tess,ou=people,$B" userPassword/read)"
expect "vault-rotator writes a service-account password" allowed "$(acl "$rot" "cn=svc-billing,ou=service-accounts,$B" userPassword/write)"
expect "vault-rotator cannot write a person's password" DENIED "$(acl "$rot" "uid=tess,ou=people,$B" userPassword/write)"
expect "vault-rotator cannot write a system bind's password" DENIED "$(acl "$rot" "$auth" userPassword/write)"
expect "vault-rotator cannot change a group" DENIED "$(acl "$rot" "cn=dance-admins,ou=groups,$B" member/write)"
expect "svc-backup may change its own password (self-managed)" allowed "$(acl "cn=svc-backup,ou=service-accounts,$B" "cn=svc-backup,ou=service-accounts,$B" userPassword/write)"
expect "svc-backup cannot change another account's password" DENIED "$(acl "cn=svc-backup,ou=service-accounts,$B" "cn=svc-billing,ou=service-accounts,$B" userPassword/write)"

echo
echo "identity-verify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
