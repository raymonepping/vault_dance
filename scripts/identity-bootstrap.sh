#!/usr/bin/env bash
# scripts/identity-bootstrap.sh: load the directory (entries, then passwords
# from Vault KV), apply the access rules, configure Keycloak realm dance.
# Idempotent.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
compose() { "$VDNC_ROOT/scripts/compose.sh" identity "$@"; }
compose --profile init up ldap-bootstrap
compose --profile init rm -f ldap-bootstrap >/dev/null
"$VDNC_ROOT/scripts/ldap-acl.sh"
compose --profile init up keycloak-bootstrap
compose --profile init rm -f keycloak-bootstrap >/dev/null
