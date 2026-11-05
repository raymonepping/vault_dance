#!/usr/bin/env bash
# scripts/hosts-keyscan.sh: pin both hosts' SSH host keys. The key is read
# through `podman exec` (a trusted channel), not scanned over the network, so
# nothing is trusted on first use: Ansible checks it via known_hosts and Vault
# via ssh_host_key.
#
#   .secrets/hosts/known_hosts      [127.0.0.1]:<port> and host-<distro>
#   .secrets/hosts/host-<d>.pub     the ed25519 public key, for Vault
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
dir="$VDNC_ROOT/.secrets/hosts"
mkdir -p "$dir"
chmod 700 "$dir"
tmp=$(mktemp)
for d in rocky ubuntu; do
  key=$(podman exec "vdnc-host-$d" cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1" "$2}')
  [ -n "$key" ] || {
    echo "hosts-keyscan: no ed25519 host key in vdnc-host-$d" >&2
    exit 1
  }
  case $d in
  rocky) port=$(vdnc_conf VDNC_PORT_SSH_ROCKY) ;;
  ubuntu) port=$(vdnc_conf VDNC_PORT_SSH_UBUNTU) ;;
  esac
  printf '[127.0.0.1]:%s %s\nhost-%s %s\n' "$port" "$key" "$d" "$key" >>"$tmp"
  printf '%s\n' "$key" >"$dir/host-$d.pub"
  echo "hosts-keyscan: host-$d $(ssh-keygen -lf "$dir/host-$d.pub" | awk '{print $2}')"
done
cat "$tmp" >"$dir/known_hosts"
rm -f "$tmp"
chmod 600 "$dir/known_hosts" "$dir"/*.pub
