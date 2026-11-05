# Security model

## Tokens

No root token survives bootstrap. `make vault-bootstrap` uses each init root
token once, creates the scoped tokens below, revokes both roots and removes
`root_token` from the init files. `make root-regen CLUSTER=seal|vault`
generates one from the saved unseal or recovery key (OTP flow) only when you
run it; `make root-revoke` revokes it again, and `make doctor` reports one
that is lying around.

| Token | Where | May | May not |
| --- | --- | --- | --- |
| `seal-admin` | vault-s | issue seal tokens through the `autounseal` role, look them up, revoke by accessor, read status | change the Transit key, policies or the seal |
| `terraform` | cluster | everything Terraform manages: auth methods, policies, groups, mounts and their configuration, password and rotation policies | unseal, step down, generate root, change audit, read snapshots |
| `operator` | cluster | register the plugin, onboard, prove, run scenarios, step down, read status and snapshots, deliver AppRole credentials | write ACL policies, auth methods or mounts (except `probe-*` scratch mounts) |
| seal token per node | vault-s | `transit/encrypt` and `transit/decrypt` on `autounseal` | anything else |

All are orphan and periodic (768h for the scoped ones, 720h for seal tokens),
in `.secrets/vault/` with mode 0600. The scoped tokens come from no token
role, so a holder cannot mint more of them.

**A token that can write ACL policies is admin-equivalent.** The `terraform`
token can rewrite any policy, its own included; it is used only by
`scripts/tf.sh`.

## People

| Persona | Groups | Vault policy | May |
| --- | --- | --- | --- |
| tess | dance-viewers | `dance-viewer` | see every configuration, schedule, version, health-check result, orphan; never a password, never an action |
| otto | + dance-operators | `+ dance-operator` | rotate, check out (break-glass and rotate-on-read), health check, re-register, unlock (AD only) |
| ada | + dance-admins | `+ dance-admin` | change rotation policies, onboard and offboard accounts and roles |

LDAP auth (Vault UI and CLI) and Keycloak with JWT auth (console) give the
same policies; `make identity-verify` checks it per persona. The viewer
policy grants exact path segments (`os/hosts/+/accounts/+`), because
`os/hosts/*` would also match `…/creds`, and no `deny`, because Vault merges
policies and a deny would also take creds away from operators.

## Machines

| Identity | Credential | May |
| --- | --- | --- |
| `dance-api` (AppRole, through vault-agent) | secret-id kept fresh by the rotator, CIDR-bound | read every credential's configuration, versions and health-check results; read a password only to prove it (never svc-reports, which rotates on read); list orphans; read the console's client secret |
| `dance-rotator` (AppRole) | handed over once by `make rotator-bootstrap` | rotate `dance-api`'s secret-id, nothing else |
| `identity-secrets` (AppRole) | non-expiring, CIDR-bound | read `kv/dance/identity/*` once at identity start |

Person actions in the console run on the person's own Vault token. The API
returns fingerprints (first 8 hex of SHA-256), never a password;
`make api-test` and the UI tests check that no answer carries a password
field.

## The directory

| Bind | May |
| --- | --- |
| `cn=vault-auth-bind,ou=system` | read people and groups (Vault LDAP auth, Keycloak federation); not passwords |
| `cn=vault-rotator,ou=system` | write `userPassword` under `ou=service-accounts` only; not people, not system binds, not groups |
| a service account | write its own `userPassword` (self-managed rotation) |
| `cn=admin` | bootstrap only (`setup_ldap.sh`, onboarding of the self-managed role) |

`make identity-verify` asks the directory with `slapacl`, which changes
nothing. The `ldap-acl` scenario removes exactly the rotator's write clause.

## Linux hosts

- `mgmt-vault` may run exactly one command as root: `/usr/sbin/chpasswd`
  (`sudoers` drop-in, validated with `visudo -cf`).
- Password login and a PTY only for the group `vault-managed`; everyone else,
  `ansible` included, is key-only; root may not log in.
- Vault pins each host's ed25519 key (`ssh_host_key`), read through
  `podman exec`, never trusted on first use. The probe shows a wrong key is
  refused ("ssh: host key mismatch").
- Initial passwords exist for seconds: a 0600 file in `$TMPDIR` for Ansible,
  stdin for Vault, then Vault rotates and the file is deleted.

## Lab limits (say them out loud)

- Unseal and recovery keys sit in `.secrets/` (0600). Production uses
  PGP-encrypted shares or an HSM.
- The host containers run with `sudo` and setuid binaries, so without
  `no-new-privileges`; `cap_drop: ALL` plus ten capabilities.
- Keycloak runs in dev mode over HTTP on loopback; the lab-only `dance-cli`
  client allows password grants for scripted tests.
- One OpenLDAP serves both people and service accounts, as most directories
  do; the scenarios break one ACL clause, never the whole directory.
- No `-tls-skip-verify`, `VAULT_SKIP_VERIFY` or
  `NODE_TLS_REJECT_UNAUTHORIZED=0` anywhere.
