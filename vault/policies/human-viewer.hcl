# dance-viewer (tess and everyone): see every credential's configuration,
# schedule, versions, policy, health-check result and the orphans. Never a
# password, never an action. No explicit "deny" here: Vault merges policies
# and a deny would also take creds away from operators, who are viewers too.
# Passwords stay out of reach because nothing here grants .../creds or
# */static-cred/*.

path "os/hosts" {
  capabilities = ["list"]
}

# Exact segments, not os/hosts/*: that glob would also match .../creds.
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
  capabilities = ["read", "list"]
}

path "ldap/static-role" {
  capabilities = ["list"]
}

path "ldap/static-role/*" {
  capabilities = ["read", "list"]
}

path "ldap-self/static-role" {
  capabilities = ["list"]
}

path "ldap-self/static-role/*" {
  capabilities = ["read", "list"]
}

path "sys/rotation/orphans" {
  capabilities = ["read", "list"]
}

path "sys/policies/rotation" {
  capabilities = ["list"]
}

path "sys/policies/rotation/*" {
  capabilities = ["read"]
}
