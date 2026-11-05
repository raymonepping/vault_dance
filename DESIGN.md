# DESIGN.md: vault_dance console

The console follows **Vault daylight glass**, the house system for every Vault
project (canonical implementation: Arcanium; contract: the `vault-ui-design`
skill). Light frosted panes, black ink, one dark ink hero per page, strong
status colours that hold WCAG AA. This file states only what vault_dance adds
or decides on top of it.

## Stack

- React 19 + Vite 8 + Tailwind v4 (`web/`), served by nginx over TLS 1.3 with
  the lab CA's listener certificate (`make gen-certs`).
- `web/src/styles/vault-glass.css` is the skill's file, unchanged;
  `shell.css` is vault_crypto's copy of the skill's (labels visually hidden
  below 1180 px instead of `display: none`, so accessible names match).
  Everything this lab adds is in `web/src/styles/app.css`.
- Fonts: Hanken Grotesk Variable and JetBrains Mono Variable via
  `@fontsource-variable`, bundled, no external requests.
- Icons: `lucide-react`. No emoji.
- CSP `style-src 'self'`: no inline styles.

## State map: colour means state

| State | Meaning | Pill |
| --- | --- | --- |
| on schedule, PASS, healthy | next rotation in the future; the login with Vault's password worked; the health check bound | `vg-pill--healthy` |
| overdue | the next rotation passed; Vault is retrying with backoff | `vg-pill--pending` |
| orphaned, FAIL, refused | Vault stopped retrying (listed and overdue); the login failed; Vault refused an action | `vg-pill--rejected` |
| recovered, people's actions | rotating on time again while Vault still lists an orphan record; rotate, check out, re-register on the timeline | `vg-pill--approved` |
| rotates on read, no schedule, not onboarded | no time-based schedule | `vg-pill--manual` |

The system's pill colours hold AA as text on their own tint. Contrast is
verified by axe (`make test-ui`, 0 violations on every page at 1440×900 and
390×844, signed in and signed out), not assumed. Rows of an overdue or
orphaned credential get a 5% amber or red wash, never a coloured rail.

## Rules for this console

1. **Vault's answer verbatim.** Refusals show Vault's error lines as `Vault
   said: <code>…</code>`. Every call is kept in the "Vault said" drawer as raw
   JSON. A failed rotation on the timeline carries the line from Vault's own
   log.
2. **Never a password.** The API returns fingerprints (first 8 hex of
   SHA-256); the console labels them. `make api-test` and the drawer test
   check that no answer has a `password` field.
3. **Proved, not reported.** A credential is green only when a login with
   Vault's current password worked. Rotate-on-read credentials are proved only
   when a person checks one out.
4. **Locks predict, Vault decides.** Buttons for actions Vault will refuse
   carry a lock and stay clickable; the refusal appears verbatim.
5. **One ink hero per page**, holding the page's message and its live counts.
6. **Machines speak mono:** account names, DNs, paths, fingerprints, cron.
7. Tables scroll inside their own frame (`.table-scroll`); a table without
   buttons is focusable. Pages never scroll sideways at 390 px.

## Pages

| Route | Hero | Main pane |
| --- | --- | --- |
| `#/overview` | Every credential, proved. | cluster (vault-s + three nodes, the active one runs the rotation manager), next rotations, what needs attention |
| `#/hosts` | Local passwords that change on time. | one card per host, a row per account: who rotates it, schedule and policy, state, proof, actions, version history |
| `#/directory` | Service accounts, rotated by Vault. | root-managed and self-managed roles, health checks, check-out, the unlock refusal |
| `#/orphans` | Retry, back off, then stop and say so. | rotation policies and who uses them, credentials that need attention, Vault's orphan list verbatim |
| `#/timeline` | What happened, in Vault's words. | rotations, failures, overdue, orphaned, recovered, proofs and people's actions, filterable |
