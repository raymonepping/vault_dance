# dance-admin (ada): change how rotation behaves and who is managed. Tune
# rotation policies, onboard and offboard accounts and static roles.

path "sys/policies/rotation/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "os/hosts/+/accounts/+" {
  capabilities = ["create", "read", "update", "delete"]
}

path "ldap/static-role/+" {
  capabilities = ["create", "read", "update", "delete"]
}

path "ldap-self/static-role/+" {
  capabilities = ["create", "read", "update", "delete"]
}
