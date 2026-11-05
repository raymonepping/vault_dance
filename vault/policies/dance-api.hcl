# dance-api: the console's own identity (vault-agent's sink). It reads how
# every credential is configured and proves it: it reads a password only to
# log in with it, inside the API, and returns a fingerprint. It cannot rotate,
# re-register, change configuration or check out a rotate-on-read credential
# (svc-reports): those run on the signed-in person's token.

# ── Cluster facts ─────────────────────────────────────────────────────────────
path "sys/license/status" {
  capabilities = ["read"]
}

path "sys/storage/raft/configuration" {
  capabilities = ["read"]
}

path "sys/capabilities-self" {
  capabilities = ["update"]
}

# ── Rotation manager ──────────────────────────────────────────────────────────
path "sys/rotation/orphans" {
  capabilities = ["read", "list"]
}

path "sys/policies/rotation/*" {
  capabilities = ["read"]
}

# ── Linux hosts: configuration, versions, and the password for proofs ────────
path "os/hosts" {
  capabilities = ["list"]
}

path "os/hosts/+" {
  capabilities = ["read"]
}

path "os/hosts/+/accounts" {
  capabilities = ["list"]
}

path "os/hosts/+/accounts/+" {
  capabilities = ["read"]
}

path "os/hosts/+/accounts/+/versions" {
  capabilities = ["read"]
}

path "os/hosts/+/accounts/+/creds" {
  capabilities = ["read"]
}

# ── Directory: configuration, health-check results, proofs ───────────────────
path "ldap/static-role" {
  capabilities = ["list"]
}

path "ldap/static-role/+" {
  capabilities = ["read"]
}

path "ldap/static-role/+/health-check/last" {
  capabilities = ["read"]
}

path "ldap-self/static-role" {
  capabilities = ["list"]
}

path "ldap-self/static-role/+" {
  capabilities = ["read"]
}

path "ldap-self/static-role/+/health-check/last" {
  capabilities = ["read"]
}

# Proofs read the current password. Not svc-reports: reading it rotates it.
path "ldap/static-cred/svc-billing" {
  capabilities = ["read"]
}

path "ldap/static-cred/svc-batch" {
  capabilities = ["read"]
}

path "ldap-self/static-cred/svc-backup" {
  capabilities = ["read"]
}

# ── The console's Keycloak client secret (code exchange, BFF) ─────────────────
path "kv/data/dance/identity/console-client-secret" {
  capabilities = ["read"]
}
