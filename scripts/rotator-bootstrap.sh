#!/usr/bin/env bash
# scripts/rotator-bootstrap.sh: deliver the rotator's own credential to
# .secrets/vault/rotator/ (0600). The only machine credential a human hands
# over; the rotator keeps the API's secret-id valid from then on.
# Idempotent: keeps a secret-id Vault still accepts. Operator token.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

role=dance-rotator
dir="$VDNC_STATE/rotator"
vault_cluster
vault_token operator
mkdir -p "$dir"
chmod 700 "$dir"
vault read -field=role_id "auth/approle/role/$role/role-id" >"$dir/role-id.tmp"
cat "$dir/role-id.tmp" >"$dir/role-id"
rm -f "$dir/role-id.tmp"
if [ -s "$dir/secret-id" ] &&
  out=$(vault write -format=json "auth/approle/role/$role/secret-id/lookup" secret_id="$(cat "$dir/secret-id")" 2>/dev/null) &&
  jq -e '.data.secret_id_accessor' <<<"$out" >/dev/null 2>&1; then
  echo "rotator-bootstrap: $role secret-id is still valid, kept"
else
  vault write -field=secret_id -f "auth/approle/role/$role/secret-id" metadata=consumer="$role" >"$dir/secret-id.tmp"
  cat "$dir/secret-id.tmp" >"$dir/secret-id"
  rm -f "$dir/secret-id.tmp"
  echo "rotator-bootstrap: $role secret-id issued (.secrets/vault/rotator/)"
fi
chmod 600 "$dir/role-id" "$dir/secret-id"
