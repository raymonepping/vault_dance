#!/usr/bin/env bash
# scripts/backup.sh: Raft snapshots of vault-s and the cluster, plus .secrets,
# into backups/<timestamp>/ (0700). Scoped tokens only (seal-admin, operator).
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VDNC_ROOT"

dest="backups/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$dest"
chmod 700 backups "$dest"
vault_node vault-s
vault_token seal-admin
vault operator raft snapshot save "$dest/vault-s.snap"
unset VAULT_TOKEN
vault_active
vault_token operator
vault operator raft snapshot save "$dest/cluster.snap"
unset VAULT_TOKEN
tar -C "$VDNC_ROOT" -czf "$dest/secrets.tgz" .secrets
echo "backup: $dest (vault-s.snap, cluster.snap, secrets.tgz)"
du -sh "$dest" | awk '{print "backup: " $1}'
