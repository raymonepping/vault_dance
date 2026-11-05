# dance-operator (otto, ada): act on a credential without changing what Vault
# manages. health-check/exec needs create as well as update: Vault treats a
# POST to a path that holds no data as create. Rotate now, run a health check, check out a credential (break-glass
# and rotate-on-read), re-register an orphan by re-writing its stored config.

path "os/hosts/+/accounts/+/rotate" {
  capabilities = ["update"]
}

path "os/hosts/+/accounts/+/creds" {
  capabilities = ["read"]
}

# Re-register: write the account's own config again (clears an orphan).
path "os/hosts/+/accounts/+" {
  capabilities = ["read", "update"]
}

path "ldap/rotate-role/*" {
  capabilities = ["update"]
}

path "ldap-self/rotate-role/*" {
  capabilities = ["update"]
}

path "ldap/static-cred/*" {
  capabilities = ["read"]
}

path "ldap-self/static-cred/*" {
  capabilities = ["read"]
}

path "ldap/static-role/+" {
  capabilities = ["read", "update"]
}

path "ldap-self/static-role/+" {
  capabilities = ["read", "update"]
}

path "ldap/static-role/+/health-check/exec" {
  capabilities = ["create", "update"]
}

path "ldap-self/static-role/+/health-check/exec" {
  capabilities = ["create", "update"]
}

path "ldap/config/health-check/exec" {
  capabilities = ["create", "update"]
}

path "ldap/static-role/+/unlock" {
  capabilities = ["update"]
}
