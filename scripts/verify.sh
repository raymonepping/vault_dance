#!/usr/bin/env bash
# scripts/verify.sh [section...]: end-to-end checks of the running lab.
# Read-only. Sections: podman vault identity hosts rotation app (default: all
# that are built). The browser-level checks are Playwright's: make test-ui.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VDNC_ROOT"

pass=0
fail=0
ok() {
  printf '  \033[32m✓\033[0m %s\n' "$*"
  pass=$((pass + 1))
}
bad() {
  printf '  \033[31m✗\033[0m %s\n' "$*"
  fail=$((fail + 1))
}
check() {
  local msg=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$msg"; else bad "$msg"; fi
}
healthy() {
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(podman container inspect "$1" --format '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && return 0
    sleep 3
  done
  return 1
}
native() { # <image>: pulled and the host's architecture, not emulated
  [ "$(podman image inspect "$1" --format '{{.Architecture}}' 2>/dev/null)" = "$(podman info --format '{{.Host.Arch}}')" ]
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

section_podman() {
  echo "podman"
  check "Podman machine answers" podman info
  check "network vdnc-internal exists" podman network exists vdnc-internal
  check "Vault Enterprise image is native arm64" native "$(vdnc_conf VAULT_ENT_IMAGE)"
  local skew=99 vm
  if vm=$(podman machine ssh date +%s 2>/dev/null | tr -d '\r' | tail -1) && [ -n "$vm" ]; then
    skew=$(($(date +%s) - vm))
    skew=${skew#-}
  fi
  check "VM clock within 5s of the Mac (${skew}s; fix: make clock-sync)" test "$skew" -le 5
}

section_vault() {
  echo "vault"
  check "listener certificate chains to the lab CA" openssl verify -CAfile vault-tls/ca-chain.pem vault-tls/vault.crt
  local node s
  for node in vault-s $VDNC_CLUSTER_NODES; do
    check "vdnc-$node healthy" healthy "vdnc-$node"
    vault_node "$node"
    s=$(vault_json 2>/dev/null || echo '{}')
    check "$node initialized and unsealed" jq -e '.initialized and (.sealed | not)' <<<"$s"
    check "$node runs 2.2.1+ent" jq -e '.version == "2.2.1+ent"' <<<"$s"
  done
  vault_node vault-s
  check "vault-s is Shamir-sealed" jq -e '.type == "shamir"' <<<"$(vault_json 2>/dev/null || echo '{}')"
  for node in $VDNC_CLUSTER_NODES; do
    vault_node "$node"
    check "$node is Transit-sealed" jq -e '.type == "transit"' <<<"$(vault_json 2>/dev/null || echo '{}')"
  done
  check "every node's own seal token is accepted by vault-s" ./scripts/seal-token-status.sh

  vault_cluster
  vault_token operator
  local peers leaders
  peers=$(vault operator raft list-peers -format=json 2>/dev/null || echo '{}')
  check "three Raft voters" jq -e '[.data.config.servers[] | select(.voter)] | length == 3' <<<"$peers"
  leaders=$(jq '[.data.config.servers[] | select(.leader)] | length' <<<"$peers" 2>/dev/null || echo 0)
  check "exactly one leader" test "$leaders" = 1
  check "licence autoloaded on the cluster" bash -c 'vault read -format=json sys/license/status | jq -e ".data.autoloaded.license_id != null"'
  check "audit device enabled on the cluster" bash -c 'vault audit list -format=json | jq -e "has(\"file/\")"'
  unset VAULT_TOKEN

  check "no root token in the seal init file" jq -e 'has("root_token") | not' .secrets/vault/seal-init.json
  check "no root token in the cluster init file" jq -e 'has("root_token") | not' .secrets/vault/vault-init.json
  check "no regenerated root token lying around (make root-revoke)" bash -c '! compgen -G ".secrets/vault/root-*" >/dev/null'
  local t
  for t in seal-admin terraform operator; do
    check "scoped token $t is 0600" test "$(stat -f '%Lp' ".secrets/vault/tokens/$t")" = 600
  done
  vault_node vault-s
  vault_token seal-admin
  check "seal-admin cannot list policies (scoped)" bash -c '! vault policy list >/dev/null 2>&1'
  unset VAULT_TOKEN
  vault_cluster
  vault_token operator
  check "operator cannot write an ACL policy (scoped)" bash -c '! vault policy write vdnc-probe-deny - <<<"path \"x\" { capabilities = [\"read\"] }" >/dev/null 2>&1'
  unset VAULT_TOKEN
  vault_token terraform
  check "terraform cannot step down the cluster (scoped)" bash -c '! vault operator step-down >/dev/null 2>&1'
  unset VAULT_TOKEN
}

section_identity() {
  echo "identity"
  check "vdnc-openldap healthy" healthy vdnc-openldap
  check "vdnc-keycloak healthy" healthy vdnc-keycloak
  check "OpenLDAP and Keycloak images are native arm64" bash -c "$(declare -f native); native '$(vdnc_conf OPENLDAP_IMAGE)' && native '$(vdnc_conf KEYCLOAK_IMAGE)'"
  check "the LDAP rotator holds its write rule (not broken)" bash -c './scripts/ldap-acl.sh --status | grep -v NOT | grep -F "may write" >/dev/null'
  check "people, groups, policies and directory ACLs (make identity-verify)" ./scripts/identity-verify.sh
}

section_hosts() {
  echo "hosts"
  local d
  for d in rocky ubuntu; do
    check "vdnc-host-$d healthy" healthy "vdnc-host-$d"
    check "host-$d image is native arm64" native "$(vdnc_conf VDNC_IMAGE_PREFIX)/host-$d:$(vdnc_conf VDNC_IMAGE_TAG)"
    check "host-$d host key pinned and unchanged" bash -c "podman exec vdnc-host-$d cat /etc/ssh/ssh_host_ed25519_key.pub | awk '{print \$1\" \"\$2}' | cmp -s - .secrets/hosts/host-$d.pub"
  done
  check "accounts, sudo rights, sshd policy and password age (make hosts-verify)" ./scripts/hosts-verify.sh
}

section_rotation() {
  echo "rotation"
  vault_active
  vault_token operator
  check "vault-plugin-secrets-os v$(vdnc_conf VDNC_OS_PLUGIN_VERSION) in the catalog" vault plugin info -version="v$(vdnc_conf VDNC_OS_PLUGIN_VERSION)" secret vault-plugin-secrets-os
  check "os/ configured, trust on first use off" bash -c 'vault read -format=json os/config | jq -e ".data.ssh_host_key_trust_on_first_use == false"'
  check "ldap/ binds as cn=vault-rotator" bash -c 'vault read -format=json ldap/config | jq -e ".data.binddn | startswith(\"cn=vault-rotator,\")"'
  check "ldap-self/ is self-managed" bash -c 'vault read -format=json ldap-self/config | jq -e ".data.self_managed == true"'
  check "rotation policy quick-step is 2 x 2" bash -c 'vault read -format=json sys/policies/rotation/quick-step | jq -e ".data.max_retries_per_cycle == 2 and .data.max_retry_cycles == 2"'
  unset VAULT_TOKEN
  local status
  status=$(./scripts/rotation-status.sh 2>&1 || true)
  check "ten credentials onboarded (make onboard)" bash -c "! grep -q 'not onboarded' <<<\"\$1\"" _ "$status"
  check "none overdue or orphaned (make rotation-status)" bash -c "! grep -qE 'overdue|ORPHANED' <<<\"\$1\"" _ "$status"
  check "every credential logs in with Vault's password (make proof)" ./scripts/proof.sh
}

section_app() {
  echo "app"
  local c web
  for c in vdnc-rotator vdnc-vault-agent vdnc-api vdnc-web; do check "$c healthy" healthy "$c"; done
  check "the API's machine identity, end to end (make agents-status)" ./scripts/agents-status.sh
  check "API health: a node unsealed, the agent token present, Vault logs readable" bash -c "curl -sf http://127.0.0.1:$(vdnc_conf VDNC_PORT_API)/api/health | jq -e '.ok and ([.vaultLogs[] | select(.file)] | length == 3)'"
  web="127.0.0.1:$(vdnc_conf VDNC_PORT_WEB)"
  check "console serves TLS 1.3 with a certificate from the lab CA" bash -c "openssl s_client -connect $web -tls1_3 -servername localhost -CAfile vault-tls/ca-chain.pem -verify_return_error </dev/null 2>/dev/null | grep -q 'Verify return code: 0'"
  check "console refuses TLS 1.2" bash -c "! openssl s_client -connect $web -tls1_2 </dev/null >/dev/null 2>&1"
  check "console sends a Content-Security-Policy" bash -c "curl -sI --cacert vault-tls/ca-chain.pem https://localhost:$(vdnc_conf VDNC_PORT_WEB)/ | grep -qi '^content-security-policy: default-src .self.'"
  check "console proxies the API" bash -c "curl -sf --cacert vault-tls/ca-chain.pem https://localhost:$(vdnc_conf VDNC_PORT_WEB)/api/credentials | jq -e '.credentials | length == 10'"
}

ansible_clean() { # both hosts in the recap, no failure, no change
  local out
  out=$(./scripts/ansible.sh hosts.yml --check)
  grep -qE '^host-rocky .*changed=0 .*failed=0' <<<"$out" && grep -qE '^host-ubuntu .*changed=0 .*failed=0' <<<"$out"
}

section_drift() {
  echo "drift"
  check "Terraform: every root plans clean (make tf-plan-all)" make -s tf-plan-all
  check "Ansible: hosts.yml in check mode changes nothing" ansible_clean
}

all="podman vault identity hosts rotation app drift"
sections=${*:-$all}
for s in $sections; do
  if declare -F "section_$s" >/dev/null; then
    "section_$s"
  else
    echo "$s"
    echo "  - not built yet"
  fi
done

echo
echo "verify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
