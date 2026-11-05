# Operations

Every command is a make target; `make help` prints them with one line each.
Targets marked "(changes state)" change something; the rest only read.

## Targets

| `make help` | Show available commands |

### Podman

| Target | What |
| --- | --- |
| `make check` | Verify Podman machine, compose provider, VM clock, memory and host tools |
| `make status` | Show this project's containers and network |
| `make ps` | List this project's containers |
| `make volumes` | List this project's named volumes and whether a container uses them |
| `make network` | (changes state) Create the vdnc-internal network if absent |
| `make ports-check` | Report host ports this stack wants that something else already holds |
| `make compose-config` | Validate every compose.yaml |
| `make clock-sync` | (changes state) Step the Podman VM's clock to the host's (after the Mac slept) |
| `make env-init` | (changes state) Create .env from .env.example; never overwrites |
| `make license` | (changes state) Install the Vault Enterprise licence: make license [LICENSE_FILE=path] |
| `make license-status` | Is the Vault Enterprise licence file present? (never prints it) |
| `make license-features` | Which licensed features the lab needs, and whether the cluster has them (names only) |

### TLS

| Target | What |
| --- | --- |
| `make gen-certs` | (changes state) Create the lab CA and the shared listener certificate; idempotent |
| `make certs-reissue` | (changes state) Re-sign the listener certificate and SIGHUP running nodes |
| `make certs-status` | Show issuer, expiry and SANs of the listener certificate |

### Vault

| Target | What |
| --- | --- |
| `make vault-bootstrap` | (changes state) Initialize vault-s and the cluster, scoped tokens, revoke root; idempotent |
| `make unseal` | (changes state) Unseal vault-s (idempotent); the cluster then unseals itself via Transit |
| `make vault-up` | (changes state) Cold start: vault-s, unseal, then vault-1..3 (auto-unseal) |
| `make vault-down` | (changes state) Stop the cluster then vault-s (containers and volumes are kept) |
| `make vault-status` | Every node: container, init, seal, HA role, Raft index, version, voters |
| `make vault-stepdown` | (changes state) Ask the active node to step down; another voter takes over |
| `make vault-login` | Print the export line that points your shell at a node: make vault-login NODE=vault-1 [TOKEN=operator] |
| `make seal-token-status` | Each node's seal token: accessor fingerprint, TTL, accepted by vault-s |
| `make seal-token-rotate` | (changes state) Replace one node's seal token and recreate only that node: make seal-token-rotate NODE=vault-2 |
| `make root-regen` | (changes state) Generate a root token from the saved key, only when you ask: make root-regen CLUSTER=seal/vault |
| `make root-revoke` | (changes state) Revoke and delete a regenerated root token: make root-revoke CLUSTER=seal/vault |

### Terraform

| Target | What |
| --- | --- |
| `make tf-platform` | (changes state) Apply terraform/vault-platform (KV, AppRoles, machine policies) |
| `make tf-identity` | (changes state) Apply terraform/vault-identity (LDAP + JWT auth, human policies, groups) |
| `make tf-rotation` | (changes state) Apply terraform/vault-rotation (password + rotation policies, os/, ldap/, ldap-self/) |
| `make tf-all` | (changes state) Every Terraform root in order |
| `make tf-plan-all` | Plan every root; fails if any has pending changes |
| `make tf-destroy` | (changes state) Destroy every root in reverse order; type DESTROY to confirm |

### Identity  people and the directory

| Target | What |
| --- | --- |
| `make identity-up` | (changes state) Start OpenLDAP + Keycloak (secrets from Vault KV, created once) |
| `make identity-down` | (changes state) Stop the identity stack; directory and realm are kept |
| `make identity-bootstrap` | (changes state) Load the directory and ACLs, set passwords from Vault, configure realm dance; idempotent |
| `make identity-verify` | Every persona and system bind: groups, Vault policies (LDAP and JWT), allowed and refused actions |
| `make identity-copy-password` | Put a persona's password on the clipboard (never printed): make identity-copy-password U=tess/otto/ada |
| `make ldap-acl` | (changes state) Re-apply the directory ACLs (idempotent) |

### Linux hosts

| Target | What |
| --- | --- |
| `make hosts-build` | (changes state) Create the Ansible key pair once, build the Rocky and Ubuntu images |
| `make hosts-up` | (changes state) Start host-rocky and host-ubuntu |
| `make hosts-down` | (changes state) Stop both hosts (their /etc/shadow survives a stop, not a recreate) |
| `make hosts-keyscan` | (changes state) Pin both hosts' SSH keys for Ansible and Vault (read through podman exec) |
| `make hosts-configure` | (changes state) Ansible: accounts, sudoers, sshd; a second run reports changed=0 |
| `make ssh` | Break-glass login with the password Vault holds now, read with YOUR vault login: `make ssh HOST=rocky/ubuntu [ACCOUNT=ops-breakglass] [CMD="id"]` |
| `make hosts-verify` | Each host: sshd, the managed users, sudo rights, sshd Match blocks, ansible key-only |

### Rotation

| Target | What |
| --- | --- |
| `make plugin-register` | (changes state) Register vault-plugin-secrets-os on the cluster (operator token); idempotent |
| `make probe` | (changes state, scratch mounts only) Prove every call the lab uses; writes docs/capabilities.md |
| `make onboard` | (changes state) Hand every Linux account and service account to Vault; create-only |
| `make demo-reset` | (changes state) Re-onboard every credential: clean, non-orphaned (type RESET to confirm) |
| `make proof` | Log in with every credential Vault holds now: PASS or FAIL, fingerprints only [CHECKOUT=1] |
| `make rotation-status` | Every credential: mode, policy, schedule, last and next rotation, orphaned |

### App

| Target | What |
| --- | --- |
| `make rotator-bootstrap` | (changes state) Deliver the rotator's own credential (the only one handed over); idempotent |
| `make agents-status` | Machine identities: rotator, secret-id expiry, agent health, token TTL |
| `make app-build` | (changes state) Build the api and web images: make app-build [TARGETS="api web"] |
| `make app-up` | (changes state) Start the rotator, agent, api and web (builds if missing) |
| `make app-down` | (changes state) Stop the app stack |
| `make app-rebuild` | (changes state) Rebuild images and recreate those services: make app-rebuild [TARGETS="api web"] |
| `make open` | Print the console, API, Keycloak and Vault addresses |
| `make trust-root` | (changes state, sudo) Trust the lab CA in the macOS System keychain so browsers accept the console |
| `make untrust-root` | (changes state, sudo) Remove the lab CA from the macOS System keychain |

### Scenarios

| Target | What |
| --- | --- |
| `make scenario-host-down` | (changes state) Stop host-rocky: rotations retry, back off, orphan |
| `make scenario-host-down-heal` | (changes state) Start host-rocky, re-register its orphans, prove |
| `make scenario-ldap-acl` | (changes state) Take write away from the LDAP rotator: root-managed roles fail, people still sign in |
| `make scenario-ldap-acl-heal` | (changes state) Give the rotator its write back, re-register, prove |
| `make scenario-password-age` | (changes state) Minimum password age on a self-managed Linux account: passwd refuses |
| `make scenario-password-age-heal` | (changes state) Remove the minimum age, re-register, prove |
| `make rotation-test` | (changes state) Every scenario end to end: each broken credential must orphan, heal and prove |

### Lifecycle

| Target | What |
| --- | --- |
| `make up` | (changes state) Start everything, then remove completed init containers (volumes kept) |
| `make down` | (changes state) Stop app, hosts, identity and vault; containers and volumes are kept |
| `make bootstrap` | (changes state) First run, from zero to verified. Idempotent |

### Tests

| Target | What |
| --- | --- |
| `make verify` | End-to-end checks: podman, vault, identity, hosts, rotation, app, console |
| `make lint` | Static checks, as in CI: shellcheck, terraform fmt and validate, ansible syntax |
| `make test-unit` | API and console unit tests (node --test; no stack needed) |
| `make api-test` | Call every API route against the live stack as ada, otto and tess |
| `make e2e-install` | (changes state) Install Playwright and Chromium for the UI suite |
| `make test-ui` | Playwright: every UI journey, headless (needs make up) |
| `make test-ui-headed` | Playwright: every UI journey in a visible browser |
| `make test-ui-report` | Open the last Playwright HTML report |
| `make screenshots` | Playwright: refresh docs/screenshots (desktop + phone) |

### Maintenance

| Target | What |
| --- | --- |
| `make doctor` | Explain what is wrong and which command fixes it (read-only) |
| `make backup` | (changes state) Raft snapshots of vault-s and the cluster, and .secrets, into backups/<timestamp>/ |
| `make clean-slate` | (changes state) DESTRUCTIVE: remove vdnc- containers and volumes, move credentials aside (type DELETE) |

Each compose stack also has `make <stack>-logs` (seal, vault, identity, hosts,
app).

## Recovery recipes

| Symptom | Cause | Fix |
| --- | --- | --- |
| Tokens look expired, rotations happen at odd times, JWT logins fail | the Podman VM clock fell behind after the Mac slept | `make clock-sync` |
| A cluster node restart-loops | vault-s is sealed or stopped, or its seal token was revoked (403 in the log) | `make unseal`; `make seal-token-status`; `make seal-token-rotate NODE=vault-N` |
| Every node standby for a few seconds after `make up` | the election is still running | `make up` waits for a leader; `make vault-status` |
| `sys/rotation/orphans` says "rotation manager is not initialized" | the call reached a performance standby | ask the active node (`make vault-login` points at vault-1; use `make vault-status` to find the leader) |
| A credential is overdue | Vault cannot rotate it and is retrying | `make rotation-status`, the console timeline (Vault's error), `make doctor` |
| A credential is orphaned (LDAP) | the retries ran out | fix the cause, then re-register: the console, or `make scenario-ldap-acl-heal` |
| A credential shows "recovered" | it rotates on time again, but Vault 2.2.1 keeps the orphan record | nothing to do; the record stays |
| A host lost its accounts or presents another host key | the container was recreated | `make up` (re-pins the key, re-applies `vault-rotation`, Ansible, re-onboards that host) |
| `make tf-plan-all` shows changes | a policy file or configuration was edited | `make tf-all` |
| A scoped token is rejected | unused for more than 32 days | `make root-regen CLUSTER=vault`, `make vault-bootstrap`, `make root-revoke CLUSTER=vault` |
| `make ssh` (or plain ssh) says "Too many authentication failures" | your SSH client offered its keys first; the hosts allow 3 attempts | `make ssh` turns keys off; for plain ssh add `-o PubkeyAuthentication=no` |
| The console is not trusted by the browser | the lab CA is not in the keychain | `make trust-root` |
| "operation not permitted" during a build | macOS TCC on `~/Documents` | the build scripts stage to `$TMPDIR`; if it persists after a Podman upgrade, restart the Podman machine (ask first: it affects every lab) |

## Starting over

```bash
make backup          # Raft snapshots of vault-s and the cluster, and .secrets
make clean-slate     # type DELETE: removes vdnc- containers and volumes
make bootstrap
```
