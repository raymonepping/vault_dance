#!/usr/bin/env bash
# scripts/tf.sh <root> <plan|apply|destroy|output|init> [terraform args...]
#
# The only supported way to run Terraform here. Exports the cluster address,
# the CA and the scoped `terraform` token (D7). Never echoes the token.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

root=${1:?Usage: tf.sh <root> <plan|apply|destroy|output|init> [args]}
action=${2:?Usage: tf.sh <root> <plan|apply|destroy|output|init> [args]}
shift 2
dir="$VDNC_ROOT/terraform/$root"
[ -f "$dir/main.tf" ] || {
  echo "tf: unknown root '$root'" >&2
  exit 64
}

vault_cluster
vault_token terraform
export VAULT_ADDR VAULT_CACERT VAULT_TOKEN

TF_VAR_network_cidr=$(podman network inspect vdnc-internal --format '{{(index .Subnets 0).Subnet}}')
export TF_VAR_network_cidr
case "$root" in
vault-identity)
  TF_VAR_keycloak_issuer="http://localhost:$(vdnc_conf VDNC_PORT_KEYCLOAK)/realms/dance"
  export TF_VAR_keycloak_issuer
  ;;
vault-rotation)
  TF_VAR_host_keys_dir="$VDNC_ROOT/.secrets/hosts"
  export TF_VAR_host_keys_dir
  ;;
esac

mkdir -p "$VDNC_ROOT/.secrets/terraform"
chmod 700 "$VDNC_ROOT/.secrets/terraform"
cd "$dir"
terraform init -input=false >/dev/null

case "$action" in
init) ;;
plan) terraform plan -input=false -detailed-exitcode "$@" ;;
apply) terraform apply -input=false -auto-approve "$@" ;;
destroy) terraform destroy -input=false -auto-approve "$@" ;;
output) terraform output "$@" ;;
*)
  echo "tf: unknown action '$action'" >&2
  exit 64
  ;;
esac
