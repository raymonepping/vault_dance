# linux-24: Linux local accounts. 24 characters from all four classes, so
# pam_pwquality (Rocky) and pam_unix (Ubuntu) accept it. The symbols avoid ':'
# (chpasswd's separator), quotes, backslash and '$' (shell and expect-safe).
length = 24
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
  min-chars = 2
}
