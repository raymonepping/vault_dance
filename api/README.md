# dance-api

The vault_dance API: every rotated credential as Vault describes it, proved
by logging in with the password Vault holds right now. `server.js` lists the
routes. Node 24, ESM, `node:http`.

## Dependencies

Two, both pinned exactly in `package.json`:

- **`ssh2`** (1.17.0): Node's standard library has no SSH client. A proof
  must log in with a password over SSH, pin the host key to the one
  `make hosts-keyscan` read through `podman exec` (no trust on first use), and
  never put the password in a process argument, so shelling out to
  `sshpass` + `ssh` is not an option inside the API. Installed without its
  optional native module (`cpu-features`).
- **`ldapts`** (9.2.0): a simple LDAP bind as the service account, for the
  same reasons: no LDAP client in the standard library, and no password in
  argv.

Everything else is the standard library (`fetch`, `node:crypto`,
`node:fs`, `node:async_hooks`).

## Identity

The API's own token comes from vault-agent's sink (AppRole `dance-api`,
policy `vault/policies/dance-api.hcl`): read configuration, read a password
only to prove it, read the orphan list. Every action (rotate, check out,
re-register, health check, unlock) runs on the signed-in person's Vault token
(`lib/session.js`), and Vault decides.

## Tests

`npm test` (no stack needed). Against the live stack: `make api-test`.
