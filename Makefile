SHELL := /bin/sh

.DEFAULT_GOAL := help

# First run:  make env-init && make license && make bootstrap
# Daily:      make up / make down   (make up unseals vault-s for you)

# Compose stacks, one project each (vdnc-<stack>). See docs/architecture.md.
STACKS  := seal vault identity hosts app
NETWORK := vdnc-internal
TF_ROOTS := vault-platform vault-identity vault-rotation

# run <script> [args]: a target whose script a later prompt adds says so.
define run
	@if [ -x ./scripts/$(firstword $(1)) ]; then ./scripts/$(1); \
	else echo "$(firstword $(1)) is not built yet (see prompts/)." >&2; exit 2; fi
endef

.PHONY: help check clock-sync status ps volumes network ports-check compose-config env-init license license-status \
	gen-certs certs-reissue certs-status \
	vault-bootstrap unseal vault-up vault-down vault-status vault-stepdown vault-login \
	seal-token-status seal-token-rotate root-regen root-revoke license-features \
	tf-platform tf-identity tf-rotation tf-all tf-plan-all tf-destroy \
	identity-up identity-down identity-bootstrap identity-verify identity-copy-password ldap-acl \
	hosts-build hosts-up hosts-down hosts-keyscan hosts-configure hosts-verify ssh \
	plugin-register probe onboard demo-reset proof rotation-status \
	rotator-bootstrap agents-status app-build app-up app-down app-rebuild open trust-root untrust-root \
	scenario-host-down scenario-host-down-heal scenario-ldap-acl scenario-ldap-acl-heal \
	scenario-password-age scenario-password-age-heal rotation-test \
	lint test-unit api-test e2e-install test-ui test-ui-headed test-ui-report screenshots \
	up down bootstrap verify doctor backup clean-slate \
	$(addsuffix -logs,$(STACKS))

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*## "; printf "vault_dance: Vault Enterprise 2.2 credential rotation on Podman + Make + Terraform + Ansible\n"} \
	  /^# ── / {gsub(/─/, ""); gsub(/^# +| +$$/, ""); printf "\n%s\n", $$0} \
	  /^[a-zA-Z0-9_-]+:.*## / {printf "  %-28s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nStacks (each has <stack>-logs):\n  %s\n' "$(STACKS)"

# ── Podman ────────────────────────────────────────────────────────────────────

check: ## Verify Podman machine, compose provider, VM clock, memory and host tools
	@./scripts/podman-check.sh

status: ## Show this project's containers and network
	@podman ps -a --filter name=^vdnc- --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
	@podman network exists $(NETWORK) && echo '$(NETWORK): present' || echo '$(NETWORK): not created'

ps: ## List this project's containers
	@podman ps -a --filter name=^vdnc-

volumes: ## List this project's named volumes and whether a container uses them
	@for v in $$(podman volume ls -q --filter name=^vdnc-); do \
		used=$$(podman ps -a --filter volume=$$v --format '{{.Names}}' | tr '\n' ' '); \
		data=$$(podman volume inspect $$v --format '{{index .Labels "io.vdnc.data"}}'); \
		printf '  %-40s %-11s %s\n' "$$v" "$${data:+persistent}" "$${used:-(unattached)}"; \
	done

network: ## (changes state) Create the vdnc-internal network if absent
	@./scripts/network.sh
	@echo "$(NETWORK): ready"

ports-check: ## Report host ports this stack wants that something else already holds
	@./scripts/ports-check.sh

compose-config: ## Validate every compose.yaml
	@for stack in $(STACKS); do \
		if [ -f compose/$$stack/compose.yaml ]; then \
			./scripts/compose.sh "$$stack" config --quiet || exit $$?; \
			echo "compose/$$stack/compose.yaml: ok"; \
		else echo "compose/$$stack/compose.yaml: not built yet"; fi; \
	done

clock-sync: ## (changes state) Step the Podman VM's clock to the host's (after the Mac slept)
	@./scripts/clock-sync.sh

env-init: ## (changes state) Create .env from .env.example; never overwrites
	@./scripts/env-init.sh

license: ## (changes state) Install the Vault Enterprise licence: make license [LICENSE_FILE=path]
	@./scripts/license.sh

license-status: ## Is the Vault Enterprise licence file present? (never prints it)
	@./scripts/license.sh --status

license-features: ## Which licensed features the lab needs, and whether the cluster has them (names only)
	$(call run,license-features.sh)

define STACK_LOGS
$(1)-logs: ## Follow $(1) logs
	@./scripts/compose.sh "$(1)" logs -f
endef
$(foreach stack,$(STACKS),$(eval $(call STACK_LOGS,$(stack))))

# ── TLS ───────────────────────────────────────────────────────────────────────

gen-certs: ## (changes state) Create the lab CA and the shared listener certificate; idempotent
	@./scripts/gen-certs.sh

certs-reissue: ## (changes state) Re-sign the listener certificate and SIGHUP running nodes
	@./scripts/gen-certs.sh --reissue

certs-status: ## Show issuer, expiry and SANs of the listener certificate
	@./scripts/gen-certs.sh --status

# ── Vault ─────────────────────────────────────────────────────────────────────

vault-bootstrap: ## (changes state) Initialize vault-s and the cluster, scoped tokens, revoke root; idempotent
	$(call run,vault-bootstrap.sh)

unseal: ## (changes state) Unseal vault-s (idempotent); the cluster then unseals itself via Transit
	$(call run,vault-unseal.sh)

vault-up: ## (changes state) Cold start: vault-s, unseal, then vault-1..3 (auto-unseal)
	$(call run,vault-up.sh)

vault-down: ## (changes state) Stop the cluster then vault-s (containers and volumes are kept)
	@./scripts/compose.sh vault stop 2>/dev/null || true
	@./scripts/compose.sh seal stop 2>/dev/null || true

vault-status: ## Every node: container, init, seal, HA role, Raft index, version, voters
	$(call run,vault-status.sh)

vault-stepdown: ## (changes state) Ask the active node to step down; another voter takes over
	$(call run,vault-stepdown.sh)

vault-login: ## Print the export line that points your shell at a node: make vault-login NODE=vault-1 [TOKEN=operator]
	$(call run,vault-login.sh $(or $(NODE),vault-1) $(or $(TOKEN),operator))

seal-token-status: ## Each node's seal token: accessor fingerprint, TTL, accepted by vault-s
	$(call run,seal-token-status.sh)

seal-token-rotate: ## (changes state) Replace one node's seal token and recreate only that node: make seal-token-rotate NODE=vault-2
	$(call run,seal-token-rotate.sh $(NODE))

root-regen: ## (changes state) Generate a root token from the saved key, only when you ask: make root-regen CLUSTER=seal|vault
	$(call run,root-regen.sh $(or $(CLUSTER),vault))

root-revoke: ## (changes state) Revoke and delete a regenerated root token: make root-revoke CLUSTER=seal|vault
	$(call run,root-regen.sh --revoke $(or $(CLUSTER),vault))

# ── Terraform ─────────────────────────────────────────────────────────────────

tf-platform: ## (changes state) Apply terraform/vault-platform (KV, AppRoles, machine policies)
	$(call run,tf.sh vault-platform apply)

tf-identity: ## (changes state) Apply terraform/vault-identity (LDAP + JWT auth, human policies, groups)
	$(call run,tf.sh vault-identity apply)

tf-rotation: ## (changes state) Apply terraform/vault-rotation (password + rotation policies, os/, ldap/, ldap-self/)
	$(call run,tf.sh vault-rotation apply)

tf-all: ## (changes state) Every Terraform root in order
	@$(MAKE) --no-print-directory tf-platform
	@$(MAKE) --no-print-directory tf-identity
	@$(MAKE) --no-print-directory tf-rotation

tf-plan-all: ## Plan every root; fails if any has pending changes
	@for r in $(TF_ROOTS); do \
		[ -f terraform/$$r/main.tf ] || { echo "$$r: not built yet"; continue; }; \
		out=$$(mktemp); code=0; ./scripts/tf.sh $$r plan >$$out 2>&1 || code=$$?; \
		case $$code in \
		0) echo "$$r: No changes." ;; \
		2) echo "$$r: CHANGES PENDING" >&2; grep -E '^  [#~+-]|Plan:' $$out >&2; rm -f $$out; exit 2 ;; \
		*) cat $$out >&2; rm -f $$out; exit $$code ;; \
		esac; rm -f $$out; \
	done

tf-destroy: ## (changes state) Destroy every root in reverse order; type DESTROY to confirm
	@printf 'This removes the rotation mounts (and every managed credential), auth methods and policies. Type DESTROY: '; \
		read answer; [ "$$answer" = DESTROY ] || { echo "Aborted."; exit 1; }
	@./scripts/tf.sh vault-rotation destroy
	@./scripts/tf.sh vault-identity destroy
	@./scripts/tf.sh vault-platform destroy

# ── Identity ── people and the directory ─────────────────────────────────────

identity-up: ## (changes state) Start OpenLDAP + Keycloak (secrets from Vault KV, created once)
	$(call run,identity-up.sh)

identity-down: ## (changes state) Stop the identity stack; directory and realm are kept
	@./scripts/compose.sh identity stop

identity-bootstrap: ## (changes state) Load the directory and ACLs, set passwords from Vault, configure realm dance; idempotent
	$(call run,identity-bootstrap.sh)

identity-verify: ## Every persona and system bind: groups, Vault policies (LDAP and JWT), allowed and refused actions
	$(call run,identity-verify.sh)

identity-copy-password: ## Put a persona's password on the clipboard (never printed): make identity-copy-password U=tess|otto|ada
	$(call run,identity-secrets.sh --copy $(or $(U),ada))

ldap-acl: ## (changes state) Re-apply the directory ACLs (idempotent)
	$(call run,ldap-acl.sh)

# ── Linux hosts ───────────────────────────────────────────────────────────────

hosts-build: ## (changes state) Create the Ansible key pair once, build the Rocky and Ubuntu images
	$(call run,hosts-build.sh)

hosts-up: ## (changes state) Start host-rocky and host-ubuntu
	$(call run,hosts-up.sh)

hosts-down: ## (changes state) Stop both hosts (their /etc/shadow survives a stop, not a recreate)
	@./scripts/compose.sh hosts stop

hosts-keyscan: ## (changes state) Pin both hosts' SSH keys for Ansible and Vault (read through podman exec)
	$(call run,hosts-keyscan.sh)

hosts-configure: ## (changes state) Ansible: accounts, sudoers, sshd; a second run reports changed=0
	$(call run,ansible.sh hosts.yml)

hosts-verify: ## Each host: sshd, the managed users, sudo rights, sshd Match blocks, ansible key-only
	$(call run,hosts-verify.sh)

ssh: ## Break-glass login with the password Vault holds now, read with YOUR vault login: make ssh HOST=rocky|ubuntu [ACCOUNT=ops-breakglass] [CMD="id"]
	$(call run,ssh.sh $(HOST) $(or $(ACCOUNT),ops-breakglass) $(if $(CMD),'$(CMD)'))

# ── Rotation ──────────────────────────────────────────────────────────────────

plugin-register: ## (changes state) Register vault-plugin-secrets-os on the cluster (operator token); idempotent
	$(call run,plugin-register.sh)

probe: ## (changes state, scratch mounts only) Prove every call the lab uses; writes docs/capabilities.md
	$(call run,probe.sh)

onboard: ## (changes state) Hand every Linux account and service account to Vault; create-only
	$(call run,onboard.sh)

demo-reset: ## (changes state) Re-onboard every credential: clean, non-orphaned (type RESET to confirm)
	$(call run,onboard.sh --reset)

proof: ## Log in with every credential Vault holds now: PASS or FAIL, fingerprints only [CHECKOUT=1]
	$(call run,proof.sh)

rotation-status: ## Every credential: mode, policy, schedule, last and next rotation, orphaned
	$(call run,rotation-status.sh)

# ── App ───────────────────────────────────────────────────────────────────────

rotator-bootstrap: ## (changes state) Deliver the rotator's own credential (the only one handed over); idempotent
	$(call run,rotator-bootstrap.sh)

agents-status: ## Machine identities: rotator, secret-id expiry, agent health, token TTL
	$(call run,agents-status.sh)

app-build: ## (changes state) Build the api and web images: make app-build [TARGETS="api web"]
	$(call run,app-build.sh $(TARGETS))

app-up: ## (changes state) Start the rotator, agent, api and web (builds if missing)
	$(call run,app-up.sh)

app-down: ## (changes state) Stop the app stack
	@./scripts/compose.sh app stop

app-rebuild: ## (changes state) Rebuild images and recreate those services: make app-rebuild [TARGETS="api web"]
	$(call run,app-build.sh $(TARGETS))
	@./scripts/compose.sh app up -d --force-recreate $(or $(TARGETS),api web)

open: ## Print the console, API, Keycloak and Vault addresses
	@bash -c '. ./scripts/common.sh && \
		echo "vault_dance console: https://localhost:$$(vdnc_conf VDNC_PORT_WEB)/" && \
		echo "API:                 http://127.0.0.1:$$(vdnc_conf VDNC_PORT_API)/api/health" && \
		echo "Keycloak:            http://localhost:$$(vdnc_conf VDNC_PORT_KEYCLOAK)/" && \
		echo "Vault UI (vault-1):  https://localhost:$$(vdnc_conf VDNC_PORT_VAULT_1)/ui" && \
		echo "Vault seal:          https://localhost:$$(vdnc_conf VDNC_PORT_VAULT_S)"'

trust-root: ## (changes state, sudo) Trust the lab CA in the macOS System keychain so browsers accept the console
	$(call run,trust-root.sh add)

untrust-root: ## (changes state, sudo) Remove the lab CA from the macOS System keychain
	$(call run,trust-root.sh remove)

# ── Scenarios ─────────────────────────────────────────────────────────────────

scenario-host-down: ## (changes state) Stop host-rocky: rotations retry, back off, orphan
	$(call run,scenario.sh host-down break)

scenario-host-down-heal: ## (changes state) Start host-rocky, re-register its orphans, prove
	$(call run,scenario.sh host-down heal)

scenario-ldap-acl: ## (changes state) Take write away from the LDAP rotator: root-managed roles fail, people still sign in
	$(call run,scenario.sh ldap-acl break)

scenario-ldap-acl-heal: ## (changes state) Give the rotator its write back, re-register, prove
	$(call run,scenario.sh ldap-acl heal)

scenario-password-age: ## (changes state) Minimum password age on a self-managed Linux account: passwd refuses
	$(call run,scenario.sh password-age break)

scenario-password-age-heal: ## (changes state) Remove the minimum age, re-register, prove
	$(call run,scenario.sh password-age heal)

rotation-test: ## (changes state) Every scenario end to end: each broken credential must orphan, heal and prove
	$(call run,test-rotation.sh)

# ── Lifecycle ─────────────────────────────────────────────────────────────────

up: ## (changes state) Start everything from a stopped machine: vault (with unseal), identity, hosts, app
	$(call run,up.sh)

down: ## (changes state) Stop app, hosts, identity and vault; containers and volumes are kept
	@./scripts/compose.sh app stop 2>/dev/null || true
	@./scripts/compose.sh hosts stop 2>/dev/null || true
	@./scripts/compose.sh identity stop 2>/dev/null || true
	@$(MAKE) --no-print-directory vault-down

bootstrap: ## (changes state) First run, from zero to verified. Idempotent
	$(call run,bootstrap.sh)

# ── Tests ─────────────────────────────────────────────────────────────────────

verify: ## End-to-end checks: podman, vault, identity, hosts, rotation, app, console
	$(call run,verify.sh)

lint: ## Static checks, as in CI: shellcheck, terraform fmt and validate, ansible syntax
	$(call run,lint.sh)

test-unit: ## API and console unit tests (node --test; no stack needed)
	@cd api && npm test
	@cd web && npm test

api-test: ## Call every API route against the live stack as ada, otto and tess
	$(call run,api-test.sh)

# Playwright against the live stack; nothing is mocked.
E2E := cd e2e && npx playwright test

e2e-install: ## (changes state) Install Playwright and Chromium for the UI suite
	@cd e2e && npm ci --no-audit --no-fund && npx playwright install chromium

test-ui: ## Playwright: every UI journey, headless (needs make up)
	@$(E2E) --grep-invert "@shots"

test-ui-headed: ## Playwright: every UI journey in a visible browser
	@$(E2E) --grep-invert "@shots" --headed

test-ui-report: ## Open the last Playwright HTML report
	@cd e2e && npx playwright show-report

screenshots: ## Playwright: refresh docs/screenshots (desktop + phone)
	@$(E2E) --grep @shots

# ── Maintenance ───────────────────────────────────────────────────────────────

doctor: ## Explain what is wrong and which command fixes it (read-only)
	$(call run,doctor.sh)

backup: ## (changes state) Raft snapshots of vault-s and the cluster, and .secrets, into backups/<timestamp>/
	$(call run,backup.sh)

clean-slate: ## (changes state) DESTRUCTIVE: remove vdnc- containers and volumes, move credentials aside (type DELETE)
	$(call run,clean-slate.sh)
