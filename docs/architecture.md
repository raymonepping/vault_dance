# Architecture

## Topology

```text
network vdnc-internal                        every Vault listener: TLS 1.3, lab CA
 ├─ seal      vault-s     Vault Enterprise 2.2.1, Raft, Shamir 1/1
 │                        transit key `autounseal`; token role `autounseal`
 ├─ vault     vault-1..3  Vault Enterprise 2.2.1, one Raft cluster (retry_join)
 │                        seal "transit" on vault-s, one seal token per node
 │                        os/ (plugin), ldap/, ldap-self/, kv/, auth ldap, jwt, approle
 ├─ identity  openldap    dc=dance,dc=lab (osixia/openldap 1.5.0)
 │            keycloak    realm `dance`, read-only LDAP federation
 ├─ hosts     host-rocky  Rocky Linux 9.8, sshd as PID 1
 │            host-ubuntu Ubuntu 24.04, sshd as PID 1
 └─ app       rotator → vault-agent → token sink → api (Node 24) ← web (nginx, TLS 1.3)
```

Five compose projects (`vdnc-<stack>`), one network, every name prefixed
`vdnc-`. `scripts/compose.sh` is the only way they are started.

## Who does what

| Tool | Owns |
| --- | --- |
| Make | The entry point. Targets are thin; scripts hold the logic. |
| Shell scripts | What must exist before Terraform: init, unseal, seal tokens, scoped tokens, revoking root (`vault-bootstrap.sh`); plugin registration; onboarding. |
| Terraform | `vault-platform` (KV, AppRoles, machine policies, the operator and terraform policies), `vault-identity` (LDAP and JWT auth, people's policies, groups), `vault-rotation` (password and rotation policies, `os/`, `ldap/`, `ldap-self/` and their configuration, the two OS hosts). Runs on the scoped `terraform` token. |
| Ansible | Inside the Linux hosts: managed accounts, `sudoers` for `mgmt-vault`, the sshd policy, password age; the host side of onboarding and of the password-age scenario. |
| `onboard.sh` | Accounts and static roles. They carry an initial password, so they are runtime state, never Terraform: a fresh random password is set on the host (Ansible) or in the directory, handed to Vault on stdin, and rotated at once. |

## Start order

A Transit-sealed node whose seal Vault is unreachable exits at start, so the
order is make's job:

1. `vault-s`, then `make unseal` (the only manual unseal, done for you by
   `make up`).
2. `vault-1..3`: each reads its own seal token from
   `.secrets/vault/seal/vault-N` and unseals through vault-s. `make up` waits
   for a leader, not only for unsealed nodes.
3. OpenLDAP and Keycloak (`identity-secrets-init` renders their secrets from
   Vault KV first).
4. The two hosts.
5. rotator, vault-agent, api, web.

## Seal tokens

Each cluster node has its own periodic orphan token (720h period) from the
token role `autounseal` on vault-s, allowed only `transit/encrypt` and
`transit/decrypt` on `autounseal`. Vault renews it while the node runs.
`make seal-token-rotate NODE=vault-2` replaces one node's token and recreates
only that node; the other two are untouched. `make seal-token-status` shows
each token's TTL.

**vault-s is a runtime dependency, not only an unseal dependency.** Vault
Enterprise seal-wraps sensitive values by default, which needs the seal at
runtime too. Stopping vault-s does not seal the cluster at once, but a node
that restarts cannot come back, and seal-wrapped writes fail.

## The rotation manager

Only the active node runs the rotation manager. `sys/rotation/orphans` on a
performance standby answers "rotation manager is not initialized", so the
scripts (`vault_active`) and the API send their calls to the active node,
found through `sys/leader`. A failed rotation is reported only in the active
node's log (`rotation-job-manager: rotation failed, attempting to re-queue`).
Each node writes its log to `/vault/logs/vault.log` on its own volume, and the
API reads those files (read-only) to put Vault's own error on the timeline.

## The OS plugin

`make plugin-register` runs `vault plugin register -download` for
`vault-plugin-secrets-os` 0.2.2+ent. The leader downloads it into its
`plugin_directory` (inside the data volume); the other nodes fetch it
themselves when the mount is used, so `os/` keeps working after a leader
change.

## Persistence

| Class | Where | What |
| --- | --- | --- |
| Persistent | named volumes labelled `io.vdnc.data=true` | Vault data and audit (four nodes), LDAP data and config, Keycloak data, the API's AppRole state |
| Logs | named volumes `vdnc-vault_vault-N-logs` | each node's server log |
| Host | `.secrets/` (0600, git-ignored) | init files, seal and scoped tokens, licence, lab CA key, Terraform state, Ansible key, pinned host keys |
| Container layer | the host containers | `/etc/shadow`: survives `make down` (stop), lost on recreate; `make up` re-pins, reconfigures and re-onboards a recreated host |
| Memory | the API | the timeline (a restart starts a new one) |

`make down` never removes a volume. Only `make clean-slate` does, after you
type DELETE.
