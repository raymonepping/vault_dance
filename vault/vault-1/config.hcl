# vault-1: one of three Raft voters. Auto-unseals through vault-s's Transit
# key with its own seal token (scripts/vault-server.sh reads it from
# /run/secrets/transit-token; it is not in this file). Hosts the OS secrets
# engine (plugin), the LDAP engines and the people's auth methods.
ui            = true
disable_mlock = true

api_addr     = "https://vault-1:8200"
cluster_addr = "https://vault-1:8201"

default_lease_ttl = "1h"
max_lease_ttl     = "768h"

# Inside the data volume, so a downloaded plugin survives a recreate.
plugin_directory = "/vault/file/plugins"

seal "transit" {
  address     = "https://vault-s:8200"
  key_name    = "autounseal"
  mount_path  = "transit/"
  tls_ca_cert = "/vault/config/tls/ca-chain.pem"
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  tls_cert_file   = "/vault/config/tls/vault.crt"
  tls_key_file    = "/vault/config/tls/vault.key"
  tls_min_version = "tls13"
}

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-1"

  retry_join {
    leader_api_addr     = "https://vault-2:8200"
    leader_ca_cert_file = "/vault/config/tls/ca-chain.pem"
  }
  retry_join {
    leader_api_addr     = "https://vault-3:8200"
    leader_ca_cert_file = "/vault/config/tls/ca-chain.pem"
  }
}

log_level = "warn"

# Also to a file the API reads (read-only): Vault 2.2.1 reports a failed
# rotation only in the active node's log (prompt 05).
log_file             = "/vault/logs/vault.log"
log_rotate_bytes     = 10485760
log_rotate_max_files = 3

# AppRole user lockout, bounded: Vault's default (5 failures, 15 minutes)
# outlasts a rotator's 60s secret-id repair (vault_goldie_locks, 2026-10-05).
user_lockout "approle" {
  lockout_threshold     = 5
  lockout_duration      = "30s"
  lockout_counter_reset = "30s"
}
