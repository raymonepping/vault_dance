# terraform (cluster): what scripts/tf.sh may change. Configuration only:
# auth methods, policies, groups, AppRoles, password and rotation policies,
# secrets engine mounts and their config, KV. It cannot unseal, step down,
# generate a root token, change audit devices or read Raft snapshots.

# Provider runs with skip_child_token = true; it only needs its own token.
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/policies/acl" {
  capabilities = ["list"]
}

path "sys/policies/password/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/policies/rotation/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/policies/rotation" {
  capabilities = ["list"]
}

# Mounts: auth methods and secrets engines.
path "sys/auth" {
  capabilities = ["read"]
}

path "sys/auth/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete"]
}

# Reading or tuning an auth method's mount settings needs sudo.
path "sys/mounts/auth/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

path "sys/plugins/catalog/*" {
  capabilities = ["read", "list"]
}

# Configuration under the mounts Terraform owns.
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "identity/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "os/config" {
  capabilities = ["create", "read", "update"]
}

path "os/hosts/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "ldap/config" {
  capabilities = ["create", "read", "update", "delete"]
}

path "ldap-self/config" {
  capabilities = ["create", "read", "update", "delete"]
}

# Ephemeral reads of bind passwords (bindpass_wo), never stored in state.
path "kv/data/dance/*" {
  capabilities = ["read"]
}

path "kv/config" {
  capabilities = ["create", "read", "update"]
}

path "sys/license/status" {
  capabilities = ["read"]
}
