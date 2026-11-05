#!/usr/bin/env bash
# scripts/hosts-up.sh: start both hosts (builds the images if missing) and
# wait until sshd answers.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
prefix=$(vdnc_conf VDNC_IMAGE_PREFIX)
tag=$(vdnc_conf VDNC_IMAGE_TAG)
for d in rocky ubuntu; do
  podman image exists "$prefix/host-$d:$tag" || "$VDNC_ROOT/scripts/hosts-build.sh"
done
"$VDNC_ROOT/scripts/network.sh"
"$VDNC_ROOT/scripts/compose.sh" hosts up -d
for c in vdnc-host-rocky vdnc-host-ubuntu; do
  for _ in $(seq 1 30); do
    [ "$(podman inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && break
    sleep 2
  done
  [ "$(podman inspect "$c" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] || {
    echo "hosts-up: $c is not healthy (make hosts-logs)" >&2
    exit 1
  }
done
echo "hosts-up: host-rocky (127.0.0.1:$(vdnc_conf VDNC_PORT_SSH_ROCKY)) and host-ubuntu (127.0.0.1:$(vdnc_conf VDNC_PORT_SSH_UBUNTU)) answer"
