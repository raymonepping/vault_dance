# Scenarios

Three failure stories, each broken precisely so the rest of the lab keeps
working. `make rotation-test` runs all three end to end and fails when a case
does not heal. Timings below are from that test on 2026-11-05 (Vault
2.2.1+ent, plugin 0.2.2+ent); they depend on where in its period a
credential was when the break started.

What every scenario shows: **no lockout**. Vault never changes half a
credential. While a rotation fails, the password Vault holds keeps working
wherever the target can be reached, and the console's proof stays green.

## host-down

```bash
make scenario-host-down        # podman stop vdnc-host-rocky
make scenario-host-down-heal   # podman start vdnc-host-rocky
```

| Step | What happens | Measured |
| --- | --- | --- |
| Break | host-rocky stops. Its three accounts cannot rotate. | |
| Overdue | `app-deploy` passes its next rotation; Vault retries with growing pauses. The timeline shows Vault's own error from its log. | overdue 33s after the break; the error on the timeline at once |
| While down | No version change; nobody (Vault included) can log in to a stopped host. | |
| Heal | The host is back; the password Vault holds logs in. | proof PASS at once |
| Recovered | Vault's next retry rotates the account; all three host-rocky accounts prove. | 12s after the heal |

Why no orphan: `app-deploy` carries rotation policy `quick-step` (2 x 2), but
an OS account on 2.2.1 with plugin 0.2.2+ent stores its policy without
applying it. Measured in prompt 05: 24 attempts in 27 minutes, cycles of 7
(Vault's default 6 retries), backoff from 15s up to about 3 minutes, never
orphaned. So an OS account heals by itself whenever the host comes back.

## ldap-acl

```bash
make scenario-ldap-acl        # scripts/ldap-acl.sh --break-rotator
make scenario-ldap-acl-heal   # restore the rule, re-register svc-billing
```

| Step | What happens | Measured |
| --- | --- | --- |
| Break | `cn=vault-rotator` loses exactly one ACL clause: write on `userPassword` under `ou=service-accounts`. Every other rule stays. | |
| Failing | `svc-billing` and `svc-batch` fail with `LDAP Result Code 50 "Insufficient Access Rights"` (on the timeline, from Vault's log). | |
| Orphaned | `svc-billing` (`quick-step`, 2 x 2) runs out of retries and Vault lists it in `sys/rotation/orphans`; automated rotation stops. | 361s after the break (up to 120s to its next scheduled rotation, then 3 attempts per cycle, 2 cycles) |
| People | tess and ada still sign in through Vault LDAP auth and through Keycloak: their bind and their entries are untouched. | |
| No lockout | `svc-billing` still binds with the password Vault holds. | |
| Heal | The rule is restored and `svc-billing` re-registered (its stored configuration written again, the documented restore). | |
| Recovered | The re-registered role rotates at its next scheduled time, not at once. | 122s after the heal |
| Record | Vault keeps the entry in `sys/rotation/orphans`; the console shows "recovered". | stays (also after a leader change, a delete and recreate, or disabling the mount) |
| Default policy | `svc-batch` (default policy, 6 x 3) never ran out of retries during the break and healed by itself. | on time at once |

Measured in prompt 05 with a 30s period: orphaned 177s after the break.

## password-age

```bash
make scenario-password-age        # Ansible: chage -m 2 ops-breakglass on host-ubuntu
make scenario-password-age-heal   # Ansible: back to 0
```

| Step | What happens | Measured |
| --- | --- | --- |
| Break | `ops-breakglass` on host-ubuntu (self-managed, rotates with `passwd` over a PTY) gets a minimum password age of two days. Its password changed less than two days ago, so `passwd` refuses. | |
| Overdue | Vault retries. Its log, and so the timeline, carries the host's own words: `You must wait longer to change your password. Process exited with status 10`. | overdue 115s after the break |
| No lockout | The account still logs in with the password Vault holds. | |
| Heal | Minimum age back to 0. | |
| Recovered | Vault's next retry rotates it. | 90s after the heal |

Only `ops-breakglass` is touched. For a parent-managed account the minimum
age should not matter, because `chpasswd` runs as root and password aging
does not restrict root; the lab does not test that.

## Afterwards

`make rotation-test` ends by proving every credential. `make demo-reset`
deletes and re-onboards all ten (fresh passwords, nothing orphaned; Vault's
old orphan records stay listed, see above).
