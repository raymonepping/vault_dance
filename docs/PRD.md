# vault_dance: product requirements

Status: built, 2026-11-05 (version 0.1.0). FR-18 and risks R1, R2, R4, R5 were updated from what the build measured; see docs/capabilities.md and docs/scenarios.md. Owner: Raymon Epping. Source: `input/01.md` to
`input/04.md` and the review of them on 2026-11-05.

## 1. Summary

vault_dance is a Vault Enterprise 2.2 lab that shows **automated credential
rotation for accounts that live outside Vault**: local Linux passwords through
the OS secrets engine, and directory passwords through LDAP static roles, both
root-managed and self-managed. Rotations run on schedules and periods, and
reusable **rotation policies** decide how often Vault retries a failed
rotation before it stops and marks the credential as orphaned.

The lab runs on one Mac (Podman machine, `podman compose`), is built with Make,
Terraform and Ansible, and has its own console (a Node API and a React UI in
Vault daylight glass) that proves every rotation instead of just reporting it.

## 2. Problem

Rotation that works is invisible, and rotation that fails is usually silent.
Teams with local break-glass accounts, service accounts in a directory, and
shared admin passwords face three questions that a slide cannot answer:

1. Does the password on the host or in the directory really match what Vault
   holds after a rotation, or did we just lock someone out?
2. What happens when the target is unreachable during a rotation: does Vault
   hammer it, give up silently, or leave a visible, auditable state?
3. Who may rotate, read or re-enable a credential, and is that enforced by
   Vault rather than by the UI?

## 3. Audience

| Who | What they need from the lab |
| --- | --- |
| Presenter (Raymon) | A demo that comes up from zero with `make`, survives a Mac sleep and a `make down && make up`, and has a scripted failure and recovery. |
| Customer architects and operators | To see the mechanism: parent-managed vs self-managed, schedules, retries, orphans, and the API calls behind each screen. |
| CxO audience | One story: "no lockouts from a temporary outage, and an explicit failure state instead of silent drift." |
| Readers of the public repo and the article | A lab they can clone and run, with honest limits. |

## 4. Goals and non-goals

### Goals

- G1. Show the OS secrets engine rotating local Linux passwords on two
  distributions, parent-managed (a `mgmt-` account with `sudo chpasswd`) and
  self-managed (the account runs `passwd` itself over a PTY).
- G2. Show LDAP static roles in both modes: root-managed through a narrowly
  privileged rotator bind, and self-managed on a separate `self_managed` mount.
- G3. Show schedules and periods (`rotation_period`, `rotation_schedule`),
  rotate-on-read with a cooldown, and LDAP health checks (2.2).
- G4. Show rotation policies: a fast-failing policy for the demo next to the
  default, the retry and backoff behaviour, the orphaned state in
  `sys/rotation/orphans`, and the documented way back.
- G5. **Prove** each credential: the console logs in over SSH or binds to LDAP
  with the password Vault holds right now and shows pass or fail, without ever
  showing the password.
- G6. Enterprise topology: `vault-s` (seal Vault) plus a three-node Raft
  cluster that auto-unseals through Transit, TLS everywhere.
- G7. People sign in with their directory identity: LDAP auth for the CLI and
  Vault UI, Keycloak OIDC (federating the same OpenLDAP) for the console. Both
  paths end in the same Vault policies.
- G8. Make, Terraform and Ansible each own a clear part of the build (section 8).

### Non-goals

- Active Directory. OpenLDAP stands in for a directory; LDAP **account
  unlock** only works with `schema=ad` and is shown as "not available here",
  never faked.
- Scale, performance or many hosts. Two Linux hosts and a handful of accounts.
- Replacing central identity. HashiCorp positions local-account rotation for a
  narrow class of accounts (break-glass, local admin). The lab says so.
- Other 2.x features (SCIM, SPIFFE, TPM auth, Agentic IAM, PQC). They have
  their own labs.
- Production hardening of the host containers. They imitate Linux servers and
  need `sudo`, so they run without `no-new-privileges` (section 10).

## 5. Personas (fictional)

| Persona | Directory group | Vault policy | Can do |
| --- | --- | --- | --- |
| `tess` (auditor) | `dance-viewers` | `dance-viewer` | See every account, schedule, policy, orphan and proof result. Cannot read a password, rotate or re-register. |
| `otto` (operator) | `dance-viewers`, `dance-operators` | `+ dance-operator` | Rotate now, run health checks, check out a rotate-on-read credential, re-register an orphan. |
| `ada` (platform admin) | all three | `+ dance-admin` | Everything above, plus change rotation policies and onboard or offboard accounts. |

Every persona password lives in Vault KV and is put on the clipboard by
`make identity-copy-password U=<uid>`, never printed.

## 6. What the lab manages

### Linux hosts (OS secrets engine, mount `os/`)

| Host | Image | Accounts |
| --- | --- | --- |
| `host-rocky` | Rocky Linux 9 (RHEL-compatible, the documented platform) | `mgmt-vault` (parent, self-managed), `app-deploy` (parent-managed by `mgmt-vault`), `ops-breakglass` (self-managed) |
| `host-ubuntu` | Ubuntu 24.04 | the same three accounts |

`mgmt-vault` may run exactly one command as root: `/usr/sbin/chpasswd`. Host
keys are pinned in Vault (`ssh_host_key`), not trusted on first use.

### Directory (OpenLDAP, `dc=dance,dc=lab`)

```text
dc=dance,dc=lab
├── ou=people            tess, otto, ada: Vault login and Keycloak
├── ou=groups            dance-viewers, dance-operators, dance-admins
├── ou=service-accounts  rotated by Vault
│     svc-billing        root-managed, rotation_period
│     svc-reports        root-managed, rotate_on_read with cooldown
│     svc-batch          root-managed, rotation_schedule (cron, UTC)
│     svc-backup         self-managed (mount ldap-self)
└── ou=system            vault-auth-bind (read-only), vault-rotator (write userPassword on ou=service-accounts only)
```

Self-managed entries may change their own `userPassword` (`by self write`).
`cn=admin` is used by the bootstrap only.

### Rotation policies

| Policy | max_retries_per_cycle | max_retry_cycles | Used by |
| --- | --- | --- | --- |
| default (Vault's) | 6 | 3 | accounts not in a scenario |
| `quick-step` | 2 | 2 | the accounts the scenarios break, so an orphan appears within minutes |

## 7. Functional requirements

### Platform

- FR-1. `make bootstrap` builds everything from empty volumes to a verified
  stack, and is idempotent. `make up` and `make down` start and stop it
  without losing state. `make down` never removes volumes.
- FR-2. `vault-s` (Enterprise 2.2.1, Shamir 1/1, Raft) serves only Transit
  key `autounseal`. `make up` unseals it from `.secrets/`.
- FR-3. `vault-1`, `vault-2`, `vault-3` (Enterprise 2.2.1) form one Raft
  cluster with `retry_join`, auto-unseal through `vault-s`, and each use their
  **own** periodic orphan seal token, so one node's token can be revoked
  without touching the others. A node restart with a valid token needs no
  human.
- FR-4. Bootstrap uses each init root token once to create scoped tokens
  (`terraform`, `seal-admin`, `operator`) and the AppRoles, writes them to
  `.secrets/` (0600), then **revokes the root tokens**. `make root-regen`
  regenerates a root token from the saved recovery or unseal key only when the
  operator runs it; `make root-revoke` revokes it again.
- FR-5. The OS plugin (`vault-plugin-secrets-os`, 0.2.2+ent or later,
  linux/arm64) is registered on the cluster and keeps working after the
  active node changes (`make vault-stepdown`).

### Identity

- FR-6. OpenLDAP holds the directory in section 6, with least-privilege
  ACLs. Passwords for people and system binds come from Vault KV.
- FR-7. Vault LDAP auth maps `dance-*` groups to policies. Keycloak federates
  the same OpenLDAP read-only and issues a `groups` claim; Vault JWT auth maps
  it to the same policies.

### Linux hosts

- FR-8. Two host containers (Rocky 9, Ubuntu 24.04, arm64) run sshd with
  password login for the managed accounts and PTY allocation, and key-only
  login for the `ansible` user.
- FR-9. Ansible (run by `make hosts-configure`) creates the accounts, the
  `sudoers` drop-in, the sshd configuration and the password-age settings,
  and is idempotent (a second run reports no changes).

### Vault configuration

- FR-10. Terraform owns auth methods, policies, groups, AppRoles, password
  policies, rotation policies, mounts and mount configuration. A
  `make tf-plan-all` after a demo must be clean.
- FR-11. Accounts and static roles carry an initial password, so they are
  **runtime state**: `make onboard` gives each account a fresh random initial
  password (set on the host by Ansible, or in LDAP by the bootstrap), hands it
  to Vault, and rotates once, so the initial value is dead within seconds.
  Initial passwords never reach Terraform state or the repo.

### Console

- FR-12. Sign-in through Keycloak (code + PKCE, BFF). Every action runs on the
  person's own Vault token; the console's own AppRole may only read platform
  facts and run proofs.
- FR-13. Overview: cluster health (three nodes, leader, seal), counts,
  next rotations, open orphans.
- FR-14. Linux hosts and Directory pages: per credential the mode, schedule,
  last and next rotation, version history, rotation policy, health check
  (LDAP) and the **proof** result with a short fingerprint of the current
  password (first 8 hex of SHA-256), never the password.
- FR-15. Retries and orphans page: rotation policies, the orphan list from
  `sys/rotation/orphans`, and a re-register action for operators.
- FR-16. Timeline: every rotation, failure, orphan and recovery the console
  observed, newest first.
- FR-17. Every screen has a "Vault said" drawer with the raw response.
  Refusals are shown verbatim. Nothing is faked: a feature that is not
  licensed, not supported on a host, or not working says so.

### Scenarios

- FR-18. `make scenario-host-down` / `scenario-host-down-heal`: a host is
  unreachable during rotation and Vault retries with growing backoff; when
  the host returns, the password Vault holds still logs in (no lockout) and
  the next retry rotates it. (Changed 2026-11-05: on
  2.2.1 with plugin 0.2.2+ent an OS account does not follow its rotation
  policy and was never orphaned in 27 minutes; the orphan story is FR-19.)
- FR-19. `make scenario-ldap-acl` / `scenario-ldap-heal`: the rotator loses
  its write permission. Root-managed roles fail and orphan; people can still
  sign in (the break is precise, not "stop OpenLDAP").
- FR-20. `make scenario-password-age` / `scenario-password-age-heal`: a
  minimum password age on a self-managed Linux account makes `passwd`
  refuse; Vault's error is shown verbatim.
- FR-21. `make demo-reset` puts every credential back to a clean, onboarded,
  non-orphaned state.

## 8. Tool responsibilities

| Tool | Owns |
| --- | --- |
| Make | The only entry point. Targets are thin; logic lives in `scripts/*.sh`. |
| Podman compose | Containers, networks and volumes, one compose project per stack (`vdnc-<stack>`), through `scripts/compose.sh`. |
| Shell (bootstrap scripts) | What must exist before Terraform: init, unseal, seal tokens, scoped tokens, root revocation, plugin registration. |
| Terraform | Vault configuration (FR-10), through `scripts/tf.sh <root>` with the scoped `terraform` token. |
| Ansible | Configuration inside the Linux hosts (FR-9) and the host side of onboarding, through `scripts/ansible.sh`. |

## 9. Non-functional requirements

- NFR-1. arm64 images only; check `Architecture` after each pull.
- NFR-2. TLS 1.3 on every Vault listener and the console; no
  `-tls-skip-verify`, `VAULT_SKIP_VERIFY` or `NODE_TLS_REJECT_UNAUTHORIZED=0`.
- NFR-3. No secret is printed by any target, test or log line: tokens, keys,
  passwords, licence. Fingerprints only.
- NFR-4. Every Podman command is filtered by the prefix `vdnc-`. The lab never
  touches another project's containers, volumes or networks.
- NFR-5. Host ports on 127.0.0.1 only: 18900 to 18903 (Vault), 13600 (API),
  13601 (console), 13602 (Keycloak), 13622 and 13623 (SSH to the hosts, for
  Ansible). All overridable in `.env`.
- NFR-6. Clock: rotations, backoff and token TTLs depend on the Podman VM
  clock. `make check` reports skew; `make clock-sync` fixes it; `make verify`
  fails on more than 5 seconds of skew.
- NFR-7. The console meets WCAG 2.2 AA (axe: 0 violations) on desktop and a
  390 px phone viewport, and follows `DESIGN.md` and the `vault-ui-design`
  skill.
- NFR-8. Docs are short, imperative and true to the code. No em dashes in
  anything published.

## 10. Security model (summary)

- Root tokens exist only during bootstrap and after an explicit
  `make root-regen`.
- Each Vault node has its own seal token (Transit `encrypt`/`decrypt` on one
  key), created through a token role on `vault-s`.
- `mgmt-vault` can only run `chpasswd` as root. The `ansible` user is
  key-only and exists for configuration, not rotation.
- The LDAP rotator can only write `userPassword` under
  `ou=service-accounts`.
- The console's AppRole can read credentials only to prove them, inside the
  API container, and returns fingerprints. Rotate-on-read roles are proved
  only when a person checks one out.
- Lab limits, stated in the README: unseal and recovery keys sit in
  `.secrets/` (0600), host containers run with `sudo` available, Keycloak runs
  in dev mode over HTTP on loopback.

## 11. Acceptance criteria

The lab is done when, after `make down && make up`:

1. `make verify` passes every check: nodes, seal tokens, identity, hosts,
   mounts, onboarded credentials, proofs, console TLS.
2. `make tf-plan-all` reports no changes, and `make hosts-configure` reports
   no changes.
3. `make rotation-test` runs all three scenarios end to end: every broken
   credential is orphaned, re-registered, and proved green again, and people
   can sign in throughout.
4. `make test-unit`, `make api-test` and `make test-ui` (Playwright, signed in
   through the real Keycloak form) pass, axe reports 0 violations.
5. `make doctor` is clean, and no root token is valid.
6. `git status --untracked-files=all` shows no secret, no `prompts/`,
   `input/`, `article/` or assistant tooling.

## 12. Demo script (10 minutes)

1. Overview: three nodes, one leader, sealed by `vault-s`. Ten credentials
   (six Linux, four directory), all proved green.
2. Linux hosts: `app-deploy` on Rocky rotates every two minutes; watch the
   fingerprint change and the SSH proof stay green. Same on Ubuntu, or Vault's
   verbatim answer if the plugin refuses it.
3. Directory: `svc-reports` checked out twice inside the cooldown (same
   fingerprint), once after (new one). Health check on `svc-billing`.
4. `make scenario-host-down`: the timeline shows Vault's failed attempts with
   growing pauses. `make scenario-host-down-heal`: the host is back, the
   password Vault holds still logs in (no lockout: Vault never changed half a
   credential), and the next retry rotates it.
5. `make scenario-ldap-acl`: the rotator loses its write rule, `svc-billing`
   (policy 2 x 2) is orphaned within minutes, people still sign in. Heal,
   then re-register as `otto`; `tess` tries the same and Vault refuses.
6. Close: what this proves and what it does not (section 4).

## 13. Risks and open questions

| # | Risk or question | How the build answers it |
| --- | --- | --- |
| R1 | The OS engine docs name RHEL (shadow-utils > 4.6) only. Ubuntu's `passwd` prompts may not match the plugin's expect workflow. | Answered: both modes work on Ubuntu 24.04. The README still states the documented support line. |
| R2 | The OS API page does not list `rotation_policy` on accounts, while the rotation policy docs say OS accounts support it. | Answered: stored, read back, not applied (default 6 retries per cycle, no orphan in 27 min). |
| R3 | Terraform provider support for the OS engine, rotation policies and self-managed LDAP is unconfirmed. | Read `terraform providers schema -json` for the pinned provider; use `vault_generic_endpoint` where a resource is missing. |
| R4 | `plugin register -download` on a three-node cluster: does every node get the binary, and does it survive a leader change? | Answered: each node fetches it when the mount is used; `os/` answered under two leaders. |
| R5 | Retry backoff timing is not documented; a scenario could take too long. | Answered: LDAP 2 x 2 orphans in 3 to 6 minutes; OS accounts never orphan (R2). `make rotation-test` takes about 20 minutes and waits on state. |
| R6 | Seal wrapping makes `vault-s` a runtime dependency, not only an unseal dependency. | Out of scope as a scenario; documented in `docs/architecture.md`. |
| R7 | Mac disk space (34 GiB free on 2026-11-05) and VM clock drift. | `make check` reports both; images are shared where possible. |

## 14. Milestones

| Prompt | Delivers |
| --- | --- |
| 01 | Foundation: layout, Makefile, wrappers, defaults, licence, lab CA |
| 02 | vault-s and the three-node cluster, seal tokens, scoped tokens, root revocation |
| 03 | Identity: OpenLDAP and Keycloak |
| 04 | Linux hosts and Ansible |
| 05 | Probe, plugin, Terraform, onboarding |
| 06 | API |
| 07 | Console UI and Playwright |
| 08 | Scenarios, rotation-test, doctor, verify |
| 09 | Docs and final validation |
