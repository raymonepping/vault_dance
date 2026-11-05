# seal-admin (vault-s): issue, inspect and revoke the per-node seal tokens.
# It cannot change the Transit key, policies or the seal itself.

# Mint a seal token through the token role (orphan, periodic, autounseal only).
path "auth/token/create/autounseal" {
  capabilities = ["update"]
}

path "auth/token/roles/autounseal" {
  capabilities = ["read"]
}

# Inspect and revoke seal tokens.
path "auth/token/lookup" {
  capabilities = ["update"]
}

path "auth/token/lookup-accessor" {
  capabilities = ["update"]
}

path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}

# Facts for status and verify.
path "transit/keys/autounseal" {
  capabilities = ["read"]
}

path "sys/policies/acl/autounseal" {
  capabilities = ["read"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/audit" {
  capabilities = ["read", "sudo"]
}

path "sys/license/status" {
  capabilities = ["read"]
}

path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
