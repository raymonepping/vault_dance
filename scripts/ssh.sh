#!/usr/bin/env bash
# scripts/ssh.sh <rocky|ubuntu> [account] [command...]: log in to a lab host as
# a Vault-managed account with the password Vault holds right now (make ssh).
#
# The break-glass flow: the password is read with YOUR Vault token (your
# `vault login`, or VAULT_TOKEN), never with one of the lab's scoped tokens,
# so Vault decides per person: an operator gets in, a viewer is refused before
# SSH starts. The password goes from `vault read` to sshpass on file
# descriptor 3: never on screen, in the clipboard or in a process argument.
# The read is in Vault's audit log, under your name.
set -euo pipefail

# common.sh unsets VAULT_TOKEN (so lab scripts never act as you by accident);
# keep the caller's token, if any, before sourcing it.
caller_token=${VAULT_TOKEN:-}
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VDNC_ROOT"

usage() {
  echo "Usage: make ssh HOST=rocky|ubuntu [ACCOUNT=ops-breakglass|app-deploy|mgmt-vault] [CMD=\"command\"]" >&2
  exit 64
}
host=${1:-}
account=${2:-ops-breakglass}
shift 2 2>/dev/null || shift $#
case "$host" in
rocky | host-rocky) host=host-rocky port=$(vdnc_conf VDNC_PORT_SSH_ROCKY) ;;
ubuntu | host-ubuntu) host=host-ubuntu port=$(vdnc_conf VDNC_PORT_SSH_UBUNTU) ;;
*) usage ;;
esac
case "$account" in
ops-breakglass | app-deploy | mgmt-vault) ;;
*)
  echo "ssh: $account is not an account Vault manages on $host (ops-breakglass, app-deploy, mgmt-vault)" >&2
  exit 64
  ;;
esac
command -v sshpass >/dev/null || {
  echo "ssh: sshpass is not installed (brew install sshpass)" >&2
  exit 127
}

vault_cluster
[ -z "$caller_token" ] || export VAULT_TOKEN=$caller_token
# Without VAULT_TOKEN the vault CLI uses your token helper (~/.vault-token).
if ! who=$(vault token lookup -format=json 2>/dev/null | jq -r '.data.display_name'); then
  echo "ssh: you are not signed in to Vault at $VAULT_ADDR. First:" >&2
  echo "  export VAULT_ADDR=$VAULT_ADDR VAULT_CACERT=$VAULT_CACERT" >&2
  echo "  make identity-copy-password U=<you> && vault login -method=ldap username=<you>" >&2
  exit 1
fi
path="os/hosts/$host/accounts/$account/creds"
# Ask first, so a refusal is Vault's words and not an SSH failure.
if ! err=$(vault read -field=version "$path" 2>&1 >/dev/null); then
  echo "ssh: Vault refused $who reading $path:" >&2
  sed 's/^/  /' <<<"$err" >&2
  exit 1
fi
echo "ssh: $who reads the current password of $account@$host from Vault and logs in (port $port)" >&2

exec sshpass -d 3 ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
  -o NumberOfPasswordPrompts=1 -o UserKnownHostsFile="$VDNC_ROOT/.secrets/hosts/known_hosts" \
  -o StrictHostKeyChecking=yes -p "$port" "$account@127.0.0.1" "$@" \
  3< <(vault read -field=password "$path")
