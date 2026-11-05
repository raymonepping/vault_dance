#!/usr/bin/env bash
# scripts/vault-up.sh: cold start. vault-s, unseal, then vault-1..3, which
# unseal themselves through Transit. A node whose seal Vault is unreachable
# exits at start, so the order matters.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
compose() { "$VDNC_ROOT/scripts/compose.sh" "$@"; }

"$VDNC_ROOT/scripts/network.sh"
compose seal up -d vault-s
"$VDNC_ROOT/scripts/vault-unseal.sh"
vault_node vault-s
vault_wait active

compose vault up -d
for node in $VDNC_CLUSTER_NODES; do
  vault_node "$node"
  vault_wait unsealed 90
done
# Unsealed is not yet serving: wait until one voter has won the election.
for _ in $(seq 1 60); do
  for node in $VDNC_CLUSTER_NODES; do
    vault_node "$node"
    if curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -e '.is_self' >/dev/null 2>&1; then
      echo "vault-up: vault-s active, vault-1..3 unsealed, $node is the leader"
      exit 0
    fi
  done
  sleep 2
done
echo "vault-up: no cluster leader after 120s (make vault-status, make vault-logs)" >&2
exit 1
