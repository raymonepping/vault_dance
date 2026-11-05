#!/usr/bin/env bash
# scripts/clean-slate.sh: DESTRUCTIVE. Removes this lab's containers and
# volumes (vdnc- only) and moves its Vault credentials, Terraform state and
# host keys aside to .secrets/legacy/<timestamp>/. Keeps the lab CA, the
# licence, the Ansible key and the images. Type DELETE to confirm.
# Back up first (make backup).
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VDNC_ROOT"

printf 'This removes every vdnc- container and volume (Vault data, directory, realm) and moves credentials aside. Type DELETE: '
read -r answer
[ "$answer" = DELETE ] || {
  echo "Aborted."
  exit 1
}
for stack in app hosts identity vault seal; do
  "$VDNC_ROOT/scripts/compose.sh" "$stack" down -v --remove-orphans 2>/dev/null || true
done
# Anything left with the prefix (one-shot containers, external volumes).
podman ps -a --filter name=^vdnc- --format '{{.Names}}' | xargs -r podman rm -f >/dev/null
podman volume ls -q --filter name=^vdnc- | xargs -r podman volume rm -f >/dev/null
podman network exists vdnc-internal && podman network rm vdnc-internal >/dev/null
legacy=".secrets/legacy/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$legacy"
for p in .secrets/vault/seal-init.json .secrets/vault/vault-init.json .secrets/vault/seal .secrets/vault/tokens \
  .secrets/vault/identity .secrets/vault/rotator .secrets/terraform .secrets/hosts; do
  [ -e "$p" ] && mv "$p" "$legacy/"
done
echo "clean-slate: containers, volumes and network removed; credentials moved to $legacy"
echo "clean-slate: start again with make bootstrap"
