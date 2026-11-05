#!/usr/bin/env bash
# scripts/vault-login.sh: print the export lines that point your shell's
# vault CLI at a node with a scoped token. It prints a command that reads the
# token file, never the token. Usage: make vault-login NODE=vault-1 TOKEN=operator
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
node=${1:-vault-1}
token=${2:-operator}
case "$(vault_cluster_of "$node")" in
seal) [ "$token" = operator ] && token=seal-admin ;;
esac
vault_node "$node"
echo "export VAULT_ADDR=$VAULT_ADDR VAULT_CACERT=$VAULT_CACERT"
echo "export VAULT_TOKEN=\$(cat $VDNC_STATE/tokens/$token)"
