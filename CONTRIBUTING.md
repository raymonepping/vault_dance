# Contributing

This is a lab, built and run on one Mac. Changes are welcome as issues or
pull requests.

1. `make bootstrap` (or `make up`), then `make verify` before you change
   anything, so you know the starting point.
2. Keep to the tools' roles (`docs/architecture.md`): Vault configuration in
   Terraform, host configuration in Ansible, credentials through
   `scripts/onboard.sh`, containers through `scripts/compose.sh`.
3. Every name starts with `vdnc-`; never touch another project's containers,
   volumes or networks.
4. Never print a token, key, password or the licence; show fingerprints.
   Fixtures and personas are fictional. gitleaks runs in CI.
5. Before a pull request: `make lint`, `make test-unit`, `make tf-plan-all`
   (clean), `make verify`, and for console changes `make test-ui` (axe must
   report 0 violations; see `DESIGN.md`). After touching rotation or
   identity: `make rotation-test`.
6. No em dashes in docs, comments or UI text.
