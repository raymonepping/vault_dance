#!/usr/bin/env bash
# scripts/bootstrap.sh: from zero to verified, in order. Idempotent: every
# step skips what already exists, so a re-run after a failure continues.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
cd "$VDNC_ROOT"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
run() {
  local script=$1
  shift
  "$VDNC_ROOT/scripts/$script" "$@"
}

step "1/14 check the machine";        run podman-check.sh
step "2/14 licence";                  [ -s .secrets/vault/vault.hclic ] || run license.sh
step "3/14 lab CA and certificate";   run gen-certs.sh
step "4/14 images";                   for i in VAULT_ENT_IMAGE OPENLDAP_IMAGE KEYCLOAK_IMAGE NODE_IMAGE NGINX_IMAGE ALPINE_IMAGE; do
                                        img=$(vdnc_conf "$i"); podman image exists "$img" || podman pull -q --platform linux/arm64 "$img" >/dev/null
                                      done
step "5/14 vault-s and the cluster";  run vault-bootstrap.sh
step "6/14 platform (Terraform)";     run tf.sh vault-platform apply
step "7/14 identity";                 run identity-up.sh; run identity-bootstrap.sh
step "8/14 people (Terraform)";       run tf.sh vault-identity apply
step "9/14 Linux hosts";              run hosts-up.sh; run hosts-keyscan.sh; run ansible.sh hosts.yml
step "10/14 OS plugin";               run plugin-register.sh
step "11/14 rotation (Terraform)";    run tf.sh vault-rotation apply
step "12/14 onboard credentials";     run onboard.sh
step "13/14 console";                 run rotator-bootstrap.sh; run app-up.sh
step "14/14 verify";                  run verify.sh
echo
echo "bootstrap: done. Console: https://localhost:$(vdnc_conf VDNC_PORT_WEB)/ (make identity-copy-password U=ada)"
