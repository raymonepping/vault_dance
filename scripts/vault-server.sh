#!/bin/sh
# scripts/vault-server.sh: entrypoint of every Vault server container.
set -eu

# Podman runs uid 100 without a usable HOME for the vault CLI's token helper.
export HOME=/tmp

# The Transit seal token is a file, never an environment variable in a compose
# file. vault-s has none (Shamir). It is read once, here: a replaced token is
# used from the next start on. Vault renews it while it runs.
if [ -e /run/secrets/transit-token ]; then
  [ -s /run/secrets/transit-token ] || {
    echo '[vault-server] the seal token file is empty; run make vault-bootstrap.' >&2
    exit 1
  }
  VAULT_TOKEN=$(cat /run/secrets/transit-token)
  export VAULT_TOKEN
fi

mkdir -p /vault/file /vault/file/plugins /vault/audit /vault/logs
chmod 0750 /vault/file/plugins
touch /vault/audit/vault-audit.log
exec vault server -config=/vault/config/config.hcl
