# Changelog

## 0.1.0 (2026-11-05)

First version.

- vault-s and a three-node Vault Enterprise 2.2.1 Raft cluster, Transit
  auto-unseal with one seal token per node, TLS 1.3, no root token after
  bootstrap (scoped `seal-admin`, `terraform`, `operator` tokens;
  `make root-regen` on request).
- OS secrets engine (`vault-plugin-secrets-os` 0.2.2+ent) on Rocky 9 and
  Ubuntu 24.04: parent-managed and self-managed accounts, pinned host keys.
- LDAP secrets engine on OpenLDAP: root-managed roles (period, rotate on read,
  cron schedule) through a write-only-where-needed rotator bind, a
  self-managed role on its own mount, health checks.
- Rotation policy `quick-step` (2 x 2); orphans; three scenarios
  (`host-down`, `ldap-acl`, `password-age`) and `make rotation-test`.
- People: LDAP auth and Keycloak (JWT) to the same policies (`tess`, `otto`,
  `ada`).
- Terraform roots `vault-platform`, `vault-identity`, `vault-rotation`;
  Ansible roles `managed_accounts`, `linux_baseline`.
- Console (Node API + React, Vault daylight glass) that proves every
  credential by logging in with it; Playwright and axe.
- `make probe`: 56 calls against the live cluster, `docs/capabilities.md`.
