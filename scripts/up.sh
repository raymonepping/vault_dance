#!/usr/bin/env bash
# scripts/up.sh: start everything from a stopped machine, in order: vault
# (unseal vault-s), identity, hosts, app. A host container that was recreated
# lost its accounts and host key: it is pinned again, reconfigured by Ansible
# and its accounts re-onboarded.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
# shellcheck source=scripts/creds.sh
source "$VDNC_ROOT/scripts/creds.sh"
cd "$VDNC_ROOT"

"$VDNC_ROOT/scripts/clock-sync.sh" || true
"$VDNC_ROOT/scripts/vault-up.sh"
"$VDNC_ROOT/scripts/identity-up.sh"
"$VDNC_ROOT/scripts/hosts-up.sh"

recreated=""
for d in rocky ubuntu; do
  key=$(podman exec "vdnc-host-$d" cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $1" "$2}')
  if [ "$key" != "$(cat ".secrets/hosts/host-$d.pub" 2>/dev/null)" ] || ! podman exec "vdnc-host-$d" id mgmt-vault >/dev/null 2>&1; then
    recreated="$recreated host-$d"
  fi
done
if [ -n "$recreated" ]; then
  echo "up: recreated host(s):$recreated; pinning keys, reconfiguring, re-onboarding"
  "$VDNC_ROOT/scripts/hosts-keyscan.sh"
  "$VDNC_ROOT/scripts/tf.sh" vault-rotation apply >/dev/null
  "$VDNC_ROOT/scripts/ansible.sh" hosts.yml >/dev/null
  ids=""
  for h in $recreated; do ids="$ids $(jq -r --arg h "$h" '.credentials[] | select(.host == $h) | .id' "$VDNC_CREDS" | tr '\n' ' ')"; done
  # shellcheck disable=SC2086
  CONFIRM=RESET "$VDNC_ROOT/scripts/onboard.sh" --reset $ids </dev/null
fi

"$VDNC_ROOT/scripts/app-up.sh"
echo "up: done. make verify to check, make doctor if something looks wrong."
