# operator (cluster): what the lab's scripts do at runtime. Register the
# plugin, onboard and prove credentials, run the scenarios, step down, read
# status. It cannot change policies, auth methods or mounts (Terraform's job),
# and it cannot generate a root token.

# Plugin catalog (register needs sudo).
path "sys/plugins/catalog" {
  capabilities = ["read", "list", "sudo"]
}

path "sys/plugins/catalog/*" {
  capabilities = ["create", "read", "update", "list", "sudo"]
}

path "sys/plugins/reload/*" {
  capabilities = ["update", "sudo"]
}

# The rotation engines: accounts, static roles, creds, rotate, health checks.
path "os/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "ldap/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "ldap-self/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/rotation/*" {
  capabilities = ["read", "list"]
}

path "sys/policies/rotation/*" {
  capabilities = ["read", "list"]
}

path "sys/policies/password/*" {
  capabilities = ["read", "list"]
}

path "sys/policies/password/+/generate" {
  capabilities = ["read"]
}

# The probe works on scratch mounts and a scratch rotation policy only.
path "sys/mounts/probe-*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "probe-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "sys/policies/rotation/probe-*" {
  capabilities = ["create", "read", "update", "delete"]
}

# Identity secrets (create-only values) and machine credentials delivery.
path "kv/data/dance/*" {
  capabilities = ["create", "read", "update"]
}

path "kv/metadata/dance/*" {
  capabilities = ["read", "list"]
}

path "auth/approle/role/+/role-id" {
  capabilities = ["read"]
}

path "auth/approle/role/+/secret-id" {
  capabilities = ["update"]
}

path "auth/approle/role/+/secret-id/lookup" {
  capabilities = ["update"]
}

path "auth/approle/role/+/secret-id-accessor/*" {
  capabilities = ["update"]
}

# Cluster operations and facts.
path "sys/step-down" {
  capabilities = ["update", "sudo"]
}

path "sys/storage/raft/configuration" {
  capabilities = ["read"]
}

path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

path "sys/storage/raft/autopilot/state" {
  capabilities = ["read"]
}

path "sys/license/status" {
  capabilities = ["read"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "sys/auth" {
  capabilities = ["read"]
}

path "sys/audit" {
  capabilities = ["read", "sudo"]
}

path "sys/capabilities" {
  capabilities = ["update"]
}

path "auth/token/lookup" {
  capabilities = ["update"]
}

path "identity/*" {
  capabilities = ["read", "list"]
}
