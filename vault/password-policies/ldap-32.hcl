# ldap-32: directory service accounts. 32 characters, the same safe symbols.
length = 32
rule "charset" {
  charset   = "abcdefghijkmnopqrstuvwxyz"
  min-chars = 2
}
rule "charset" {
  charset   = "ABCDEFGHJKLMNPQRSTUVWXYZ"
  min-chars = 2
}
rule "charset" {
  charset   = "23456789"
  min-chars = 2
}
rule "charset" {
  charset   = "!#%+,-.=@^_~"
  min-chars = 1
}
