#!/usr/bin/env bash
# scripts/app-up.sh: build images if missing, then start the app stack.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

prefix=$(vdnc_conf VDNC_IMAGE_PREFIX)
tag=$(vdnc_conf VDNC_IMAGE_TAG)
services=${APP_SERVICES:-}
for t in api web; do
  [ -f "$VDNC_ROOT/$t/Containerfile" ] || continue
  if ! podman image exists "$prefix/$t:$tag"; then
    echo "app-up: $prefix/$t:$tag not found, building"
    "$VDNC_ROOT/scripts/app-build.sh" "$t"
  fi
done
[ -s "$VDNC_STATE/rotator/secret-id" ] || {
  echo "app-up: the rotator has no credential yet: run make rotator-bootstrap" >&2
  exit 1
}
# shellcheck disable=SC2086
"$VDNC_ROOT/scripts/compose.sh" app up -d $services
echo "app-up: stack started"
echo "  Console: https://localhost:$(vdnc_conf VDNC_PORT_WEB)/   (lab CA; make trust-root to trust it)"
echo "  API:     http://127.0.0.1:$(vdnc_conf VDNC_PORT_API)/api/health"
