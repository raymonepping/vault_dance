# Build state

What each prompt in `prompts/` did, what it deferred, and what was learned on
the way. Newest last.

## 01: Foundation (2026-11-05)

Done:

- Layout per prompt 01. Copied from `../vault_crypto/scripts` (renamed
  `vcry`→`vdnc`, em dashes removed): `common.sh`, `compose.sh`,
  `podman-check.sh`, `network.sh`, `ports-check.sh`, `env-init.sh`,
  `clock-sync.sh`, `gen-certs.sh`, `license.sh`; `.gitleaks.toml`,
  `.editorconfig`, `.github/`.
- `common.sh` has no `vault_root`; it adds `vault_token <name>` (scoped
  tokens, D7), `vault_cluster` (first unsealed node of vault-1..3),
  `vault_port_of` and `fingerprint`.
- `scripts/ansible.sh`: runs `ansible-playbook` with `</dev/null` and output
  through `cat` (Ansible core 2.21 refuses non-blocking stdio in the agent
  shell).
- `config/defaults.conf`: Vault 2.2.1-ent for all four nodes, Rocky
  `9.8.20260525.0`, Ubuntu `noble-20261024.1` (both arm64 on Docker Hub),
  OS plugin `0.2.2+ent`, ports 18900-18903, 13600-13602, 13622-13623.
- `Makefile`: every target of prompts 01 to 09; targets whose script does not
  exist yet say "not built yet".
- `make check` minimum memory raised to 8 GiB and clock skew limit to 5s (PRD
  NFR-6).

Validated: `make help`, `make check` (skew 1s, 46 GiB), `make env-init`,
`make license` (from the `.env` string, 1412 bytes), `make license-status`,
`make gen-certs`, `make certs-status` (13 SANs, chain verifies),
`make ports-check` (all nine free).

## 02: vault-s and the three-node cluster (2026-11-05)

Done:

- `vault/vault-s/config.hcl` (Enterprise, Shamir 1/1) and
  `vault/vault-{1,2,3}/config.hcl` (Raft `retry_join` to the other two,
  `seal "transit"`, `plugin_directory = "/vault/file/plugins"` inside the data
  volume so a downloaded plugin survives a recreate). Policies `autounseal`,
  `seal-admin`, `terraform`, `operator`.
- `compose/seal` (vault-s only, no seal agent or rotator) and `compose/vault`
  (YAML anchor, one `.secrets/vault/seal/vault-N` file per node mounted at
  `/run/secrets/transit-token`).
- `vault-bootstrap.sh`: vault_crypto's four-case init table; token role
  `autounseal` (orphan, renewable, `token_period=720h`); one seal token per
  node, reissued only when vault-s rejects it; scoped tokens `seal-admin`,
  `terraform`, `operator` (orphan, periodic 768h, **no token role**, so a
  holder cannot mint more); then both root tokens revoked and `root_token`
  removed from the init JSON. Re-runs work on the scoped tokens alone.
- `vault-up.sh` waits for a leader, not only for unsealed nodes.
  `vault-status.sh` (four nodes and Raft peers), `vault-stepdown.sh`,
  `vault-login.sh` (prints a `$(cat …)` line, never a token),
  `seal-token-status.sh`, `seal-token-rotate.sh`, `root-regen.sh`,
  `license-features.sh`, `verify.sh` sections `podman` and `vault`.
- `vault_token` renews the periodic token on every use.

Open question 1, answered: the licence (expires 2035-12-31) lists
`OpenLDAP Secrets Engine`, `Seal Wrapping`, `Agentic IAM` and more. The OS
secrets engine and rotation policies have no feature name of their own; they
come with the Enterprise edition.

Validated: `make vault-bootstrap` three times (first run hit the bug below,
then no changes), `make vault-down && make vault-up`, `make vault-status`,
`make vault-stepdown` (vault-2 → vault-1), `make seal-token-rotate
NODE=vault-2` (only vault-2 recreated, old accessor revoked, the other two
tokens untouched), `make seal-token-status`, `make license-features`,
`make verify podman vault` 35/35.

Not validated: `make root-regen` / `make root-revoke`. The agent's permission
rules block it from generating a root token, as intended (D6): the user runs
it.

Learned:

- **Revoking a root token needs the right cluster address.** The first run
  revoked the cluster root, then tried the seal root against the cluster
  (403) because `VAULT_ADDR` still pointed there. The seal init file was not
  changed (the revoke is checked before the token is dropped), so a re-run
  fixed it. `revoke_root` now selects the node itself.
- **Unsealed is not serving.** Right after a cold start all three nodes
  report unsealed standby for a few seconds; `vault-up` now waits for a
  leader.
- `eza` behind `ls` hangs the agent's shell when it is the last command of a
  heredoc batch; use `/bin/ls`.

## 03: Platform Terraform and identity (2026-11-05)

Done:

- `scripts/tf.sh` on the scoped `terraform` token (`skip_child_token =
  true`). `terraform/vault-platform`: the `operator` and `terraform` policies
  (Terraform owns them from here: no root token is left to change them), KV
  v2, AppRoles `dance-api`, `dance-rotator`, `identity-secrets`, policy
  `dance-api`.
- `compose/identity` and its scripts from vault_crypto (renamed): realm
  `dance`, Keycloak federation binds as `vault-auth-bind` (read only), not as
  `cn=admin`. `identity-secrets.sh` on the operator token, plus
  `kv/dance/identity/system/{vault-auth-bind,vault-rotator}` rendered to the
  init volume and set by `setup_ldap.sh`.
- `bootstrap.ldif`: PRD section 6 (16 entries; system binds and service
  accounts are `inetOrgPerson`, because `simpleSecurityObject` demands a
  password at add time). `scripts/ldap-acl.sh` replaces `olcAccess` as a whole
  over `ldapi://` (`--break-rotator`, `--heal`, `--status`).
- `terraform/vault-identity`: LDAP auth (bind `vault-auth-bind`, ephemeral KV
  read + `bindpass_wo`), JWT role `console`, external groups, policies
  `dance-viewer`, `dance-operator`, `dance-admin`.
- `scripts/identity-verify.sh` (27 checks): LDAP and JWT logins give the same
  policies per persona, allowed and refused paths, directory ACLs asked with
  `slapacl` (changes nothing). `verify.sh` section `identity`.

Validated: `make identity-bootstrap` twice (second: 0 added), `make
identity-verify` 27/27, `make tf-plan-all` clean, `make verify` 40/40.

Learned:

- **Reading an auth mount's tune needs `sudo`** (`sys/mounts/auth/*/tune`).
  Terraform's refresh failed on it, so Terraform could not fix its own policy
  through Terraform; the `terraform` token wrote `terraform.hcl` once with
  `vault policy write` (it may write ACL policies), then Terraform took over.
  Note for the security model: a token that can write ACL policies is admin
  equivalent.
- **A `deny` in one policy beats a grant in another.** The viewer policy
  denied `*/static-cred/*`; operators are viewers too, so otto lost checkout.
  Viewer now grants nothing secret instead of denying.
- **`os/hosts/*` also matches `…/accounts/<a>/creds`.** Viewer paths use `+`
  segments.
- `slapacl` exits 0 for DENIED; read its last line.
- sed renaming `vcry-ldap`→`dance-ldap` ran before `vcry-`→`vdnc-` and left
  one container named `dance-ldap-bootstrap` (removed). Every
  `container_name` is now checked for the prefix.

## 04: Linux hosts and Ansible (2026-11-05)

Done:

- `hosts/{rocky,ubuntu}/Containerfile` (Rocky 9.8, Ubuntu 24.04.5): sshd,
  sudo, passwd, python3; the `ansible` user with the key from
  `.secrets/ansible/` baked at build time; host keys created at first start
  (`hosts/start-sshd.sh`, which also removes `pam_nologin`'s flag: no systemd
  clears it). `scripts/hosts-build.sh` stages the context to `$TMPDIR`
  (`--format docker`, arm64 checked).
- `compose/hosts`: `cap_drop: ALL` plus the ten caps sshd, sudo and passwd
  need; no `no-new-privileges` (setuid binaries). SSH on 127.0.0.1:13622 and
  13623.
- `scripts/hosts-keyscan.sh`: host keys read through `podman exec`, written
  to `.secrets/hosts/known_hosts` and `host-<d>.pub` (for Vault's
  `ssh_host_key`). No trust on first use anywhere.
- `ansible.cfg`, `ansible/inventory.yml`, `group_vars/lab_hosts.yml`, roles
  `managed_accounts` (group, three locked users with
  `update_password: on_create`, password age 0/99999, sudoers drop-in
  validated by `visudo -cf`) and `linux_baseline` (sshd drop-in
  `10-vault-dance.conf`: keys only, `Match User` for the three managed
  accounts with password login and PTY; SIGHUP to PID 1), playbooks
  `hosts.yml` and `onboard.yml`.
- `scripts/hosts-verify.sh` (28 checks through `podman exec`), `verify.sh`
  section `hosts`.

Validated: `make hosts-build`, `make hosts-up`, `make hosts-keyscan`,
`make hosts-configure` twice (second: changed=0, no warnings),
`make hosts-verify` 28/28, `make verify hosts` 7/7.

Learned:

- `sshd -t -o Include=…` is refused ("Include directive not supported as a
  command-line option"). The template is validated alone (`sshd -t -f %s`),
  then the whole configuration by a second task.
- Ansible core 2.21 manages Rocky 9's Python 3.9 without a warning.

## 05: Probe, OS plugin, Terraform rotation root, onboarding (2026-11-05)

Done:

- `scripts/plugin-register.sh` (`make plugin-register`, `--check` steps down
  and reads `os/config` under each leader).
- `scripts/probe.sh` (`make probe`): 55 calls on scratch mounts, scratch host
  accounts (`ansible/probe-accounts.yml`) and scratch entries, all removed;
  `docs/capabilities.md`: 55 matched, 0 did not.
- `terraform/vault-rotation`: password policies `linux-24` and `ldap-32`
  (`vault/password-policies/`), rotation policy `quick-step` (2 x 2), mount
  `os/` (plugin v0.2.2+ent) with `vault_os_secret_backend` and two
  `vault_os_secret_backend_host` with pinned keys, `ldap/` (bind
  `vault-rotator`, `bindpass_wo` from KV) and `ldap-self/`
  (`self_managed = true`).
- `config/credentials.json` (the ten credentials; read by the scripts and the
  API), `scripts/creds.sh` (paths, SSH and LDAP login helpers, orphans),
  `scripts/onboard.sh` (create-only; `--reset` for `make demo-reset`),
  `scripts/proof.sh`, `scripts/rotation-status.sh`, `verify.sh` section
  `rotation`.
- sshd `Match Group vault-managed` instead of a user list, so scratch
  accounts get password login without touching the real ones.
- Every cluster node also logs to `/vault/logs/vault.log` (own volume, 0640
  vault:1000), applied with a rolling recreate (followers first).

Open questions, answered:

2. `plugin register -download` puts the binary only in the leader's plugin
   directory. The other nodes fetch it themselves when a mount uses it;
   `os/` answered under two different leaders. No pinned-binary fallback
   needed.
3. An OS account (and host) **stores** `rotation_policy` but the rotation
   manager does not apply it: 24 attempts in 27 minutes in cycles of 7
   (Vault's default 6 retries), backoff 15s doubling to ~3 min, never
   orphaned. LDAP static roles do follow it.
4. Self-managed rotation works on Ubuntu 24.04 (outside the documented
   platform), parent-managed too. Every probe login passed.
5. LDAP root-managed, period 30s, 2 x 2, rotator write removed: orphaned
   177s after the break (3 attempts per cycle). OS: see 3.
6. Provider 5.13 has `vault_os_secret_backend`, `_host`, `_account` (no
   `rotation_policy` argument), `vault_rotation_policy`,
   `vault_password_policy`, `vault_ldap_secret_backend` (`self_managed`,
   `bindpass_wo`; `binddn` required even when self-managed: set `""`) and
   `vault_ldap_secret_backend_static_role` (`password_wo`). No
   `vault_generic_endpoint` needed.

Validated: `make probe` 55/55, `make tf-rotation`, `make tf-plan-all` clean
(3 roots), `make onboard` twice (second: 0 onboarded), after a full period
every version advanced and `make proof` PASS for all nine readable
credentials, `make verify` 55/55.

Learned:

- **`sys/rotation/orphans` answers only on the active node.** Performance
  standbys say "rotation manager is not initialized". `vault_active` in
  `common.sh`; the API sends every call to the active node.
- **An orphan record outlives the fix** (re-register, delete and recreate,
  leader change). The lab derives `orphaned` from "listed AND
  next_vault_rotation in the past"; listed but on time is `recovered`.
- **The rotation error is only in the active node's log**
  (`rotation-job-manager: rotation failed, attempting to re-queue`). Account
  and role reads have no error field; hence the log files for the API.
- **The cooldown of rotate-on-read counts from the last rotation**, including
  the one at role creation.
- **The VM clock fell 315s behind in ~15 minutes** although chrony has
  `makestep 1.0 -1`; a measurement taken across the jump was discarded.
  `make clock-sync` fixed it. Timing work starts with a skew check.
- `ls` (eza) and `===` (zsh `=cmd` expansion) both bit the agent shell; and
  `diff` is aliased to delta: use `/usr/bin/diff`.

## 06: The API (2026-11-05)

Done:

- `api/` (Node 24, ESM): `lib/vault.js` (from vault_crypto; every call to the
  active node, found through `sys/leader` and cached 5s), `lib/session.js`
  (BFF from vault_crypto; actions name the capability they need),
  `lib/limit.js`, `lib/credentials.js` (catalogue, paths, state, person
  actions), `lib/proof.js` (`ssh2` with the pinned host key, `ldapts` bind),
  `lib/watch.js` (5s poll, timeline, a proof after every rotation and once
  at start), `lib/vaultlog.js` (rotation failures from Vault's log files),
  `server.js`, `README.md` (why the two dependencies).
- `compose/app`: volume-init (also copies the lab CA leaf into `web-tls` for
  nginx), rotator, vault-agent, api (read-only; host keys and the three Vault
  log volumes read-only), web. `scripts/{app-build,app-up,rotator-bootstrap,
  agents-status,api-test}.sh`, `verify.sh` section `app`.
- Unit tests 18 (session, PKCE, cookies, capability map, state derivation,
  timeline diff, log parsing, id validation, rotate-on-read refusal).

Validated: `make test-unit` 18/18 (API), `make api-test` 38/38 (tess
refused four actions; otto rotated, checked out twice inside the cooldown
with the same fingerprint, re-registered an OS account and an LDAP role;
unlock refused "not supported for schema openldap"), `make verify` 65/65.

Learned:

- **There is no LIST for `sys/policies/rotation` on 2.2.1** ("unsupported
  path"); the API reads the policies the catalogue names. Added to the probe.
- **`health-check/exec` needs `create`, not only `update`.**
- Re-registering an OS account works without sending its password again.
- `umask 077` from `common.sh` made the API image's `config/` unreadable for
  uid 1000 (EACCES); `app-build.sh` now runs `chmod -R a+rX` on the build
  context.

## 07: The console (2026-11-05)

Done:

- `web/` from vault_crypto (React 19, Vite 8, Tailwind 4; skill CSS; `api.js`,
  `hooks.js`, `latest.js`, `components/ui.jsx`, `Footer.jsx`), `App.jsx`
  with five pages, `components/creds.jsx` (state pill, schedule in words,
  timing, proof cell, actions), pages Overview, Linux hosts (with version
  history drawer), Directory (check-out, health check, the unlock refusal),
  Retries & orphans, Timeline. nginx TLS 1.3 with the lab CA leaf, CSP.
- `DESIGN.md` (state map, rules, pages), `scripts/trust-root.sh` (the lab
  CA, by SHA-1).
- `e2e/`: harness from vault_crypto; the browser trusts exactly the leaf's
  and the lab CA's keys (`--ignore-certificate-errors-spki-list`, never
  `ignoreHTTPSErrors`). Specs: shell (navigation, one hero, phone overflow,
  the drawer holds no password field), credentials (ten, both hosts PASS,
  rotate then prove, versions, check-out inside the cooldown, health check,
  unlock refused, policies, timeline filter), authz (signed out, tess refused
  verbatim, otto rotates and is named on the timeline, sign-out), served (TLS
  1.3, lab CA, CSP), a11y (axe on five pages, desktop and phone, and signed
  out), screenshots (`docs/screenshots/`, ten files).

Validated: `make test-ui` 28/28 (axe 0 violations), web unit tests 3/3,
`make screenshots`, `make verify` 65/65. Screens reviewed at 1440 and 390 px;
fixed in one pass: row headers centred, the "when" column breaking mid-phrase,
the unlock button stretched, overview tiles 3+1 instead of 2 x 2.

Learned:

- **An orphan record survives disabling its mount.** The probe's scratch
  roles stay in `sys/rotation/orphans` after the mounts are gone; the console
  labels them "not one of this lab's credentials".
- axe flagged the grey `vg-pill--manual` on the timeline (contrast) and a
  sideways-scrolling table with no buttons (`scrollable-region-focusable`);
  action events are blue pills now and that table is focusable.
- Playwright's `request` fixture does not use the browser's SPKI flag; the CSP
  test reads headers with Node `https` against the lab CA instead.

## 08: Scenarios, rotation-test, doctor, full verify (2026-11-05)

Done:

- `scripts/scenario.sh` (`make scenario-<name>[-heal]`): host-down (stop
  host-rocky), ldap-acl (drop exactly the rotator's write clause; heal
  re-registers svc-billing), password-age (Ansible `scenario.yml`, minimum age
  2 days on ops-breakglass@host-ubuntu). `cred_state` and `cred_mark` in
  `creds.sh` (the console's state rule in bash).
- `scripts/test-rotation.sh` (`make rotation-test`): every case waits on
  Vault's state with a bound, checks Vault's error on the API timeline, that
  the held password still works (no lockout), that people still sign in
  during ldap-acl, and that each case heals.
- `scripts/doctor.sh`, `backup.sh`, `clean-slate.sh` (vdnc- only, type
  DELETE; not run), `bootstrap.sh` (14 steps), `up.sh` (re-pins, reconfigures
  and re-onboards a recreated host), `lint.sh` (shellcheck, terraform fmt and
  validate, ansible-lint), `verify.sh` section `drift` (tf-plan-all clean,
  Ansible check mode changed=0 on both hosts).
- `docs/scenarios.md` with the measured timings.

Validated: `make rotation-test`: host-down 7/7 and ldap-acl 10/10 in the
first run; password-age failed one step there (below), passed 6/6 after the
fix; every credential proved after both runs. `make doctor` clean, `make
verify` 67/67, `make lint` clean (60 scripts, 3 roots, ansible-lint
production profile), API unit tests 19/19.

Measured (see docs/scenarios.md): host-down overdue after 33s, rotated 12s
after the heal; svc-billing orphaned 361s after the ACL break, rotated 122s
after the re-register (at its next scheduled time, not at once); svc-batch
(default policy) healed by itself; password-age overdue after 66 to 115s,
rotated 21 to 90s after the heal.

Learned:

- **Vault logs a multi-line error as continuation lines** (`error=` then
  `| …`), as with passwd's "You must wait longer to change your password.
  Process exited with status 10". The API's parser read only `error="…"` and
  missed it; `parseLog` now collects continuation lines (unit test added).
- **A re-registered role is re-queued, not rotated**: the first rotation
  comes at its next scheduled time.
- ansible-lint wants `hosts:` templating to have a default and task names to
  start upper-case.

## 09: Docs and final validation (2026-11-05)

Done:

- `README.md` (what it shows, what it proves and does not, first run, daily
  use, the demo, checks, ports), `docs/architecture.md`,
  `docs/security-model.md`, `docs/operations.md` (every make target from
  `make help`, recovery recipes), `docs/scenarios.md`, `CHANGELOG.md`
  (0.1.0), `CONTRIBUTING.md`. `.claude/CLAUDE.md` and `AGENTS.md` carry the
  final commands and the measured Vault behaviour. `docs/PRD.md` status
  "built"; FR-18, the demo script and risks R1, R2, R4, R5 follow the
  measurements.
- CI: the API now has dependencies, so `npm ci` runs before its tests;
  `lint.sh` skips Ansible where it is not installed; Dependabot covers
  `/api`.

Validated from a stopped stack (`make down`, then `make up`): `make verify`
67/67, `make doctor` clean, `make tf-plan-all` clean (3 roots), Ansible check
mode changed=0 (in verify), `make test-unit` 19 + 3, `make api-test` 38/38,
`make test-ui` 28/28 (axe 0 violations), `make lint` clean, `make probe`
56/56, `make proof` all PASS. `make rotation-test` ran in prompt 08 (all three
scenarios pass; not repeated here). `git status`: nothing private appears.

Not run: `make root-regen` / `make root-revoke` (only the user regenerates
root), `make clean-slate` (destructive), `make bootstrap` from empty volumes
(each of its steps ran individually; the script itself has not run end to
end).

Left as found:

- Em dashes remain in `web/src/styles/vault-glass.css` and `shell.css` (the
  skill's files, kept identical), in the scaffold's `.gitignore`, and in
  `docs/release-checklist.md`, which appeared at 11:52 from outside this build.
- gitleaks finds 11 secret-shaped values, all in git-ignored paths
  (`.secrets/`, `vault-tls/vault.key`, `e2e/.auth/`, `input/05.md`).

## Afterwards: `make ssh` (2026-11-05)

Asked by the user after signing in to the console as ada.

- `scripts/ssh.sh` (`make ssh HOST=rocky|ubuntu [ACCOUNT=] [CMD=]`): the
  break-glass login. Reads the password with the caller's own Vault token
  (`vault login` or `VAULT_TOKEN`; `common.sh` unsets `VAULT_TOKEN`, so the
  script keeps it before sourcing), asks Vault first so a refusal is Vault's
  text, then `sshpass -d 3` from `vault read` (never on screen, in the
  clipboard or in argv), keys off (`PubkeyAuthentication=no`), host key
  pinned.
- Tested: ada on host-rocky (ops-breakglass) and host-ubuntu (app-deploy),
  otto as mgmt-vault on both hosts (6 of 6 after one failure, below), tess
  refused by Vault with 403 before SSH, a non-managed account refused by the
  script, not signed in: instructions.

Learned:

- **Plain `ssh` fails with "Too many authentication failures"** when the
  client offers its keys first: the hosts allow 3 attempts
  (`MaxAuthTries 3`). Keys off fixes it; the hardening stays.
- `CMD="a; b"` was split by make's shell (`b` ran on the Mac); the target
  quotes `CMD` now.
- One `make ssh` as otto to mgmt-vault@host-ubuntu was refused by sshd
  (`Failed keyboard-interactive/pam`, 11:28:26 UTC) while the proof 11
  seconds later passed with Vault's password, and six retries succeeded.
  Not reproduced, cause unknown.
