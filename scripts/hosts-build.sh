#!/usr/bin/env bash
# scripts/hosts-build.sh: create the Ansible key pair once, then build the two
# host images (arm64). The build context is staged to $TMPDIR: macOS TCC can
# refuse Podman reads under ~/Documents, and xattrs break builds.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VDNC_ROOT"

key=.secrets/ansible/id_ed25519
mkdir -p .secrets/ansible
chmod 700 .secrets/ansible
if [ ! -s "$key" ]; then
  ssh-keygen -q -t ed25519 -N '' -C vdnc-ansible -f "$key"
  echo "hosts-build: Ansible key pair created (.secrets/ansible/)"
fi
pub=$(cat "$key.pub")
prefix=$(vdnc_conf VDNC_IMAGE_PREFIX)
tag=$(vdnc_conf VDNC_IMAGE_TAG)

for distro in rocky ubuntu; do
  ctx=$(mktemp -d "${TMPDIR:-/tmp}/vdnc-host-$distro.XXXXXX")
  COPYFILE_DISABLE=1 cp "hosts/$distro/Containerfile" hosts/start-sshd.sh "$ctx/"
  xattr -rc "$ctx" 2>/dev/null || true
  case $distro in
  rocky) base_arg="ROCKY_IMAGE=$(vdnc_conf ROCKY_IMAGE)" ;;
  ubuntu) base_arg="UBUNTU_IMAGE=$(vdnc_conf UBUNTU_IMAGE)" ;;
  esac
  podman build -q --format docker --platform linux/arm64 \
    --build-arg "$base_arg" --build-arg "ANSIBLE_PUBKEY=$pub" \
    -t "$prefix/host-$distro:$tag" "$ctx" >/dev/null
  rm -rf "$ctx"
  arch=$(podman image inspect "$prefix/host-$distro:$tag" --format '{{.Architecture}}')
  [ "$arch" = arm64 ] || {
    echo "hosts-build: host-$distro is $arch, not arm64" >&2
    exit 1
  }
  echo "hosts-build: $prefix/host-$distro:$tag built ($arch)"
done
