terraform {
  required_version = ">= 1.5.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.13"
    }
  }
  backend "local" {
    path = "../../.secrets/terraform/vault-rotation.tfstate"
  }
}

# The cluster, with the scoped `terraform` token: exported by scripts/tf.sh.
provider "vault" {
  skip_child_token = true
}

# How credentials rotate: password policies, rotation policies, and the two
# engines' mounts and configuration. The accounts and static roles carry an
# initial password, so they are runtime state (scripts/onboard.sh), never
# Terraform (D8). Provider 5.13 has native resources for all of this; its
# vault_os_secret_backend_account has no rotation_policy argument, one more
# reason accounts are not Terraform's.
#
# Needs: make plugin-register (the OS plugin in the catalog), make
# hosts-keyscan (the pinned host keys), make identity-up (the LDAP binds).

variable "network_cidr" {
  description = "Subnet of vdnc-internal (unused here; tf.sh exports it for every root)"
  type        = string
  default     = ""
}

variable "host_keys_dir" {
  description = "Where make hosts-keyscan wrote host-<distro>.pub"
  type        = string
}

variable "os_plugin_version" {
  description = "The registered vault-plugin-secrets-os version"
  type        = string
  default     = "v0.2.2+ent"
}

locals {
  base  = "dc=dance,dc=lab"
  hosts = ["host-rocky", "host-ubuntu"]
}

# ── Password policies ─────────────────────────────────────────────────────────
resource "vault_password_policy" "linux" {
  name   = "linux-24"
  policy = file("${path.module}/../../vault/password-policies/linux-24.hcl")
}

resource "vault_password_policy" "ldap" {
  name   = "ldap-32"
  policy = file("${path.module}/../../vault/password-policies/ldap-32.hcl")
}

# ── Rotation policies ─────────────────────────────────────────────────────────
# Vault's default (no name) is 6 retries per cycle, 3 cycles. quick-step makes
# a broken credential orphan within minutes, for the scenarios.
resource "vault_rotation_policy" "quick_step" {
  name                  = "quick-step"
  max_retries_per_cycle = 2
  max_retry_cycles      = 2
}

# ── Linux hosts: the OS secrets engine ────────────────────────────────────────
resource "vault_mount" "os" {
  path           = "os"
  type           = "vault-plugin-secrets-os"
  plugin_version = var.os_plugin_version
  description    = "Local Linux passwords on host-rocky and host-ubuntu"
}

resource "vault_os_secret_backend" "os" {
  mount        = vault_mount.os.path
  max_versions = 10
  # Host keys are pinned per host below; never trust on first use.
  ssh_host_key_trust_on_first_use = false
}

resource "vault_os_secret_backend_host" "host" {
  for_each        = toset(local.hosts)
  mount           = vault_mount.os.path
  name            = each.key
  address         = each.key
  port            = 22
  ssh_host_key    = trimspace(file("${var.host_keys_dir}/${each.key}.pub"))
  password_policy = vault_password_policy.linux.name
  custom_metadata = { distro = trimprefix(each.key, "host-") }
  depends_on      = [vault_os_secret_backend.os]
}

# ── Directory: LDAP secrets engine, root-managed ──────────────────────────────
ephemeral "vault_kv_secret_v2" "rotator" {
  mount = "kv"
  name  = "dance/identity/system/vault-rotator"
}

resource "vault_ldap_secret_backend" "ldap" {
  path                = "ldap"
  description         = "Service accounts Vault rotates through cn=vault-rotator"
  url                 = "ldap://openldap:389"
  schema              = "openldap"
  binddn              = "cn=vault-rotator,ou=system,${local.base}"
  bindpass_wo         = ephemeral.vault_kv_secret_v2.rotator.data["value"]
  bindpass_wo_version = 1
  userdn              = "ou=service-accounts,${local.base}"
  userattr            = "cn"
  password_policy     = vault_password_policy.ldap.name
}

# ── Directory: LDAP secrets engine, self-managed ──────────────────────────────
# A self-managed mount has no bind credential: each role rotates with its own
# password. The flag is immutable and the mount holds only self-managed roles.
resource "vault_ldap_secret_backend" "ldap_self" {
  path         = "ldap-self"
  description  = "Service accounts that rotate their own password"
  url          = "ldap://openldap:389"
  schema       = "openldap"
  self_managed = true
  # The provider requires binddn; a self-managed mount has none (Vault stores "").
  binddn          = ""
  userdn          = "ou=service-accounts,${local.base}"
  userattr        = "cn"
  password_policy = vault_password_policy.ldap.name
}

output "mounts" {
  value = [vault_mount.os.path, vault_ldap_secret_backend.ldap.path, vault_ldap_secret_backend.ldap_self.path]
}
