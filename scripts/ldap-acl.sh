#!/usr/bin/env bash
# scripts/ldap-acl.sh [--break-rotator | --heal | --status]
#
# The directory's access rules, applied over ldapi:// inside vdnc-openldap
# (SASL EXTERNAL as the container's root: the only way to change cn=config).
# The whole olcAccess list is replaced in a known order, so a run is
# idempotent. --break-rotator drops exactly one clause: vault-rotator's write
# on service-account passwords (prompt 08's ldap-acl scenario). People can
# still sign in during the break. --heal (or no argument) restores it.
set -euo pipefail
B="dc=dance,dc=lab"
C=vdnc-openldap

mode=${1:-apply}
rotator_clause="by dn.exact=\"cn=vault-rotator,ou=system,$B\" write"
case "$mode" in
apply | --heal) rot="$rotator_clause" ;;
--break-rotator) rot="" ;;
--status)
  if podman exec "$C" ldapsearch -Q -LLL -Y EXTERNAL -H ldapi:/// -b "olcDatabase={1}mdb,cn=config" olcAccess 2>/dev/null |
    tr -d '\n ' | grep -F 'cn=vault-rotator,ou=system' | grep -F 'write' >/dev/null; then
    echo "ldap-acl: vault-rotator may write service-account passwords"
  else
    echo "ldap-acl: vault-rotator may NOT write service-account passwords (broken on purpose?)"
  fi
  exit 0
  ;;
*)
  echo "Usage: $0 [--break-rotator | --heal | --status]" >&2
  exit 64
  ;;
esac

podman exec -i "$C" ldapmodify -Q -Y EXTERNAL -H ldapi:/// >/dev/null <<LDIF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcAccess
olcAccess: {0}to * by dn.exact=gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth manage by * break
olcAccess: {1}to dn.subtree="ou=service-accounts,$B" attrs=userPassword by self write by dn.exact="cn=admin,$B" write $rot by anonymous auth by * none
olcAccess: {2}to attrs=userPassword,shadowLastChange by self write by dn.exact="cn=admin,$B" write by anonymous auth by * none
olcAccess: {3}to * by dn.exact="cn=admin,$B" write by dn.exact="cn=vault-auth-bind,ou=system,$B" read by dn.exact="cn=vault-rotator,ou=system,$B" read by users read by * none
LDIF
case "$mode" in
--break-rotator) echo "ldap-acl: vault-rotator's write on service-account passwords REMOVED" ;;
*) echo "ldap-acl: access rules applied (vault-rotator writes service-account passwords only)" ;;
esac
