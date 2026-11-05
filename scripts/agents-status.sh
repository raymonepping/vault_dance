#!/usr/bin/env bash
# scripts/agents-status.sh: the API's machine identity end to end: rotator
# health, its credential, the API secret-id's expiry, agent health and token
# TTL; then every node's seal token. Read-only. Exit 1 when a link is broken.
set -uo pipefail
failed=0
state() { podman inspect "$1" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || echo "not created"; }

rot=vdnc-rotator
role=dance-api
agent=vdnc-vault-agent
printf '%-10s %-10s %-10s %-20s %-21s %-10s %s\n' IDENTITY ROTATOR CREDENTIAL SECRET-ID-EXPIRES LAST-ROTATION AGENT TOKEN-TTL
rs=$(state "$rot")
login=$(podman exec "$rot" sh -c 't=$(vault write -field=token auth/approle/login role_id="$(cat /run/rotator/role-id)" secret_id="$(cat /run/rotator/secret-id)" 2>/dev/null) && VAULT_TOKEN=$t vault token revoke -self >/dev/null 2>&1 && echo ok || echo REJECTED' 2>/dev/null || echo "-")
meta=$(podman exec "$rot" cat "/run/approle/$role/metadata.json" 2>/dev/null || echo '{}')
as=$(state "$agent")
ttl=$(podman exec "$agent" sh -c 'VAULT_TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null) vault token lookup -format=json 2>/dev/null' 2>/dev/null | jq -r '.data.ttl // empty' 2>/dev/null)
if [ -n "$ttl" ]; then ttl="$((ttl / 60))m"; else
  ttl=REJECTED
  failed=1
fi
{ [ "$rs" = healthy ] && [ "$login" = ok ]; } || failed=1
printf '%-10s %-10s %-10s %-20s %-21s %-10s %s\n' "$role" "$rs" "$login" \
  "$(jq -r '.expiration_time // "-"' <<<"$meta" | cut -c1-19)" "$(jq -r '.last_rotation_utc // "-"' <<<"$meta")" "$as" "$ttl"
echo
"$(dirname -- "$0")/seal-token-status.sh" || failed=1
exit "$failed"
