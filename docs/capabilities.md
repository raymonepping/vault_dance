# What Vault 2.2.1 answered

Written by `make probe` on 2026-11-05 against the live cluster
(vault-plugin-secrets-os v0.2.2+ent). Scratch mounts, scratch accounts and
scratch directory entries only; all removed afterwards. Secrets appear as
fingerprints (first 8 hex of SHA-256).

Result: **56 matched, 0 did not.**

| Area | Call | Expected | Vault's answer | Match |
| --- | --- | --- | --- | --- |
| rotation | `GET sys/rotation/orphans (vault-1, active)` | answers | {"orphans":["probe-ldap/static-role/probe-root","probe-ldap/static-role/probe-root2","ldap/static-role/svc-billing"]}  | yes |
| rotation | `GET sys/rotation/orphans (vault-2, perf standby)` | refused: only the active node runs the rotation manager | 1 error occurred:* rotation manager is not initialized  | yes |
| rotation | `GET sys/rotation/orphans (vault-3, perf standby)` | refused: only the active node runs the rotation manager | 1 error occurred:* rotation manager is not initialized  | yes |
| rotation | `POST sys/policies/rotation/probe-quick` | created (2 x 2) | Success! Data written to: sys/policies/rotation/probe-quick  | yes |
| rotation | `GET sys/policies/rotation/probe-quick` | both fields | {"max_retries_per_cycle":2,"max_retry_cycles":2}  | yes |
| rotation | `LIST sys/policies/rotation` | no list endpoint in 2.2.1 (the API reads policies by name) | unsupported path  | yes |
| rotation | `POST sys/policies/rotation/probe-bad (no fields)` | refused: both fields are required | missing max_retries_per_cycle  | yes |
| os | `GET sys/plugins/catalog/secret/vault-plugin-secrets-os` | v0.2.2+ent registered | v0.2.2+ent  | yes |
| os | `POST sys/mounts/probe-os (plugin)` | mounted | Success! Enabled the vault-plugin-secrets-os secrets engine version v0.2.2+ent at: probe-os/  | yes |
| os | `POST probe-os/config` | TOFU off, 5 versions | Success! Data written to: probe-os/config  | yes |
| os | `POST probe-os/hosts/host-rocky (ssh_host_key pinned)` | created | Success! Data written to: probe-os/hosts/host-rocky  | yes |
| os | `POST probe-os/hosts/host-rocky/accounts/probe-parent` | created; verify_connection logs in | Success! Data written to: probe-os/hosts/host-rocky/accounts/probe-parent  | yes |
| os | `POST probe-os/hosts/host-rocky/accounts/probe-child (parent_account_ref)` | created | Success! Data written to: probe-os/hosts/host-rocky/accounts/probe-child  | yes |
| os | `POST probe-os/hosts/host-rocky/accounts/probe-self (self-managed)` | created | Success! Data written to: probe-os/hosts/host-rocky/accounts/probe-self  | yes |
| os | `POST probe-os/hosts/host-ubuntu (ssh_host_key pinned)` | created | Success! Data written to: probe-os/hosts/host-ubuntu  | yes |
| os | `POST probe-os/hosts/host-ubuntu/accounts/probe-parent` | created; verify_connection logs in | Success! Data written to: probe-os/hosts/host-ubuntu/accounts/probe-parent  | yes |
| os | `POST probe-os/hosts/host-ubuntu/accounts/probe-child (parent_account_ref)` | created | Success! Data written to: probe-os/hosts/host-ubuntu/accounts/probe-child  | yes |
| os | `POST probe-os/hosts/host-ubuntu/accounts/probe-self (self-managed)` | created | Success! Data written to: probe-os/hosts/host-ubuntu/accounts/probe-self  | yes |
| os | `rotation_policy on an OS account (open question 3)` | stored and read back | probe-quick  | yes |
| os | `POST probe-os/hosts/probe-wrongkey/accounts/x (other host's key)` | refused: pinned host key does not match | failed to connect to host "host-rocky:22" as user "probe-self": ssh: handshake failed: ssh: host key mismatch  | yes |
| os | `POST probe-os/hosts/host-rocky/accounts/probe-parent/rotate` | rotated | Success! Data written to: probe-os/hosts/host-rocky/accounts/probe-parent/rotate  | yes |
| os | `GET probe-os/hosts/host-rocky/accounts/probe-parent/creds + SSH` | SSH login with Vault's password: PASS | v2, fp fec466af, PASS  | yes |
| os | `POST probe-os/hosts/host-rocky/accounts/probe-child/rotate` | rotated | Success! Data written to: probe-os/hosts/host-rocky/accounts/probe-child/rotate  | yes |
| os | `GET probe-os/hosts/host-rocky/accounts/probe-child/creds + SSH` | SSH login with Vault's password: PASS | v2, fp baf90a48, PASS  | yes |
| os | `POST probe-os/hosts/host-rocky/accounts/probe-self/rotate` | rotated | Success! Data written to: probe-os/hosts/host-rocky/accounts/probe-self/rotate  | yes |
| os | `GET probe-os/hosts/host-rocky/accounts/probe-self/creds + SSH` | SSH login with Vault's password: PASS | v2, fp 9a25abe4, PASS  | yes |
| os | `POST probe-os/hosts/host-ubuntu/accounts/probe-parent/rotate` | rotated | Success! Data written to: probe-os/hosts/host-ubuntu/accounts/probe-parent/rotate  | yes |
| os | `GET probe-os/hosts/host-ubuntu/accounts/probe-parent/creds + SSH` | SSH login with Vault's password: PASS | v2, fp 22a7a2d5, PASS  | yes |
| os | `POST probe-os/hosts/host-ubuntu/accounts/probe-child/rotate` | rotated | Success! Data written to: probe-os/hosts/host-ubuntu/accounts/probe-child/rotate  | yes |
| os | `GET probe-os/hosts/host-ubuntu/accounts/probe-child/creds + SSH` | SSH login with Vault's password: PASS | v2, fp 478564bd, PASS  | yes |
| os | `POST probe-os/hosts/host-ubuntu/accounts/probe-self/rotate` | rotated | Success! Data written to: probe-os/hosts/host-ubuntu/accounts/probe-self/rotate  | yes |
| os | `GET probe-os/hosts/host-ubuntu/accounts/probe-self/creds + SSH` | SSH login with Vault's password (open question 4: self-managed on Ubuntu): PASS | v2, fp 3239aab8, PASS  | yes |
| os | `GET probe-os/hosts/host-rocky/accounts/probe-child/versions` | version history | {"current_version":2,"oldest_version":1,"versions":["1","2"]}  | yes |
| os | `POST …/probe-child/versions/1/restore` | Vault's record only | Success! Data written to: probe-os/hosts/host-rocky/accounts/probe-child/versions/1/restore  | yes |
| os | `SSH login after restore` | FAIL: restore does not touch the host | FAIL  | yes |
| os | `POST …/probe-child/rotate after restore` | the parent sets a new password again | Success! Data written to: probe-os/hosts/host-rocky/accounts/probe-child/rotate  | yes |
| os | `SSH login after the next rotation` | PASS | PASS  | yes |
| os | `POST …/probe-child (rotation_period=30)` | next_vault_rotation set | 2026-11-05T11:13:02Z  | yes |
| ldap | `POST sys/mounts/probe-ldap` | mounted | Success! Enabled the ldap secrets engine at: probe-ldap/  | yes |
| ldap | `POST probe-ldap/config (binddn vault-rotator)` | configured | Success! Data written to: probe-ldap/config  | yes |
| ldap | `POST probe-ldap/static-role/probe-root` | imported and rotated | Success! Data written to: probe-ldap/static-role/probe-root  | yes |
| ldap | `GET probe-ldap/static-cred/probe-root + bind` | PASS | fp 4fd1131d, PASS  | yes |
| ldap | `POST sys/mounts/probe-ldap-self` | mounted | Success! Enabled the ldap secrets engine at: probe-ldap-self/  | yes |
| ldap | `POST probe-ldap-self/config (self_managed=true, no bindpass)` | configured | Success! Data written to: probe-ldap-self/config  | yes |
| ldap | `POST probe-ldap-self/static-role/probe-self (no password)` | refused: self-managed needs the current password | password is a required field for a self-managed static role  | yes |
| ldap | `POST probe-ldap-self/static-role/probe-self (dn + password)` | imported and rotated with its own password | Success! Data written to: probe-ldap-self/static-role/probe-self  | yes |
| ldap | `GET probe-ldap-self/static-cred/probe-self + bind` | PASS | fp 9e63f127, PASS  | yes |
| ldap | `POST probe-ldap/static-role/probe-root/health-check/exec` | healthy | {"healthy":true,"reason":"All checks passed","type":"static_role_credentials"}  | yes |
| ldap | `GET probe-ldap/static-role/probe-root/health-check/last` | cached result | {"healthy":true,"reason":"All checks passed"}  | yes |
| ldap | `POST probe-ldap/config/health-check/exec` | bind as vault-rotator works | "successfully connected and authenticated to LDAP server at ldap://openldap:389"  | yes |
| ldap | `POST probe-ldap-self/static-role/probe-self/health-check/exec` | healthy | "All checks passed"  | yes |
| ldap | `PUT probe-ldap/static-role/probe-root/unlock` | refused: Active Directory only | unlock not supported for schema "openldap" yet  | yes |
| ldap | `GET probe-ldap/static-cred/probe-root twice (rotate_on_read, cooldown 15s)` | first rotates, second inside the cooldown does not | rotated_on_read true then false; fp e1fb0e14 then e1fb0e14  | yes |
| ldap | `POST probe-ldap/static-role/probe-root (rotation_schedule */5)` | next on a 5-minute boundary | 2026-11-05T11:15:00Z  | yes |
| ldap | `POST probe-ldap/static-role/probe-root (period and schedule)` | refused: one or the other | mutually exclusive fields rotation_schedule and rotation_period were both specified; only one of them can be provided  | yes |
| ldap | `rotation_policy on an LDAP static role` | stored | probe-quick  | yes |

## Measured by hand (prompt 05), not by this probe

These take minutes and change the scenario accounts' state, so `make probe`
does not repeat them; `make rotation-test` exercises them end to end.

- **Time to orphan, LDAP root-managed** (`rotation_period=30`, policy 2 x 2,
  rotator's write rule removed): listed in `sys/rotation/orphans` 177s after
  the break. Attempts: 3 in the first cycle (10s, then 20s apart), 3 in the
  second, one more, then none.
- **OS accounts did not follow their rotation policy** (plugin 0.2.2+ent).
  With `rotation_policy=probe-quick` (2 x 2) on the account, later also on the
  host, the parent locked: 24 attempts in 27 minutes, in cycles of 7 (the
  first plus 6 retries, Vault's default per cycle), backoff 15s doubling to
  about 3 minutes, and no entry in `sys/rotation/orphans`. The policy is
  stored and read back, but not applied. Vault keeps retrying; that the account
  heals by itself once the host accepts the login again is what make
  rotation-test checks (scenario host-down).
- **An orphan record outlives the fix.** Re-writing the role (the documented
  restore), deleting and recreating it, and a leader change all left the
  entry in `sys/rotation/orphans`, while the role rotated on schedule again.
  Disabling the mount does not remove it either: the probe's own scratch
  roles stay listed after `make probe` removed their mounts. The lab
  therefore calls a credential orphaned only when it is listed AND its
  `next_vault_rotation` is in the past.
- **The rotation error is only in the active node's log** (`rotation-job-manager:
  rotation failed, attempting to re-queue: rotationID=… error="…"`). An account
  or role read shows no error field; `next_vault_rotation` stays in the past
  while Vault retries.
