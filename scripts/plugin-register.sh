#!/usr/bin/env bash
# scripts/plugin-register.sh: register vault-plugin-secrets-os on the cluster
# (operator token), idempotent.
#
# `-download` fetches the release from releases.hashicorp.com into the
# leader's plugin_directory and registers it in the (replicated) catalog. The
# other nodes download it themselves when a mount uses it, so the mount keeps
# working after a leader change (prompt 05, open question 2). --check steps
# down until every node has been leader once and reads os/config each time.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

version=$(vdnc_conf VDNC_OS_PLUGIN_VERSION)
vault_active
vault_token operator
if vault plugin info -format=json -version="v$version" secret vault-plugin-secrets-os >/dev/null 2>&1; then
  echo "plugin-register: vault-plugin-secrets-os v$version is already in the catalog"
else
  vault plugin register -download -version="$version" secret vault-plugin-secrets-os >/dev/null
  echo "plugin-register: vault-plugin-secrets-os v$version downloaded and registered"
fi
vault plugin info -format=json -version="v$version" secret vault-plugin-secrets-os |
  jq -r '"plugin-register: catalog entry \(.name) \(.version), sha256 \(.sha256[0:12])…"'
unset VAULT_TOKEN

[ "${1:-}" = --check ] || exit 0
seen=""
for _ in 1 2 3 4 5 6; do
  vault_active
  leader=$(curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -r '.leader_address' | sed -E 's#https://([^:]+):.*#\1#')
  vault_token operator
  if vault read -format=json os/config >/dev/null 2>&1; then
    echo "plugin-register: os/ answers with $leader active"
  else
    echo "plugin-register: os/ does NOT answer with $leader active" >&2
    exit 1
  fi
  unset VAULT_TOKEN
  case " $seen " in *" $leader "*) ;; *) seen="$seen $leader" ;; esac
  [ "$(wc -w <<<"$seen")" -ge 3 ] && break
  "$VDNC_ROOT/scripts/vault-stepdown.sh" >/dev/null
done
# Raft picks the next leader; a node may not win in a handful of step-downs.
# Two different leaders prove the other nodes fetched the plugin themselves.
[ "$(wc -w <<<"$seen")" -ge 2 ] || {
  echo "plugin-register: only$seen was ever leader; cannot tell" >&2
  exit 1
}
echo "plugin-register: os/ answered under$(wc -w <<<"$seen" | tr -d ' ') different leaders:$seen"
