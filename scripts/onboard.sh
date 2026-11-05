#!/usr/bin/env bash
# scripts/onboard.sh [--reset] [id...]: hand credentials to Vault.
#
# For every credential in config/credentials.json (or the ids given), unless
# Vault already manages it:
#
#   os           a random initial password goes into a 0600 file in $TMPDIR,
#                Ansible sets it on the host (ansible/onboard.yml), Vault gets
#                it on stdin (verify_connection logs in once), Vault rotates at
#                once, the file is removed. The initial value is dead within
#                seconds and never reaches Terraform, the repo or a terminal.
#   ldap         root-managed: Vault imports the entry and rotates it at once
#                (skip_import_rotation=false) through cn=vault-rotator.
#   ldap-self    self-managed: the initial password is set by cn=admin inside
#                the openldap container, then handed to Vault, which rotates
#                with the account's own credentials from then on.
#
# --reset (make demo-reset): delete and re-onboard every credential, children
# before parents on the way out, parents first on the way in. Runs on the
# operator token.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
# shellcheck source=scripts/creds.sh
source "$VDNC_ROOT/scripts/creds.sh"
cd "$VDNC_ROOT"

reset=false
if [ "${1:-}" = --reset ]; then
  reset=true
  shift
  if [ -t 0 ] && [ "${CONFIRM:-}" != RESET ]; then
    printf 'This deletes and re-onboards every credential (their passwords change). Type RESET: '
    read -r answer
    [ "$answer" = RESET ] || {
      echo "Aborted."
      exit 1
    }
  fi
fi
ids=${*:-$(cred_ids)}

vault_active
vault_token operator

log() { echo "[onboard] $*"; }
exists() { vault read -format=json "$(cred_config_path "$1")" >/dev/null 2>&1; }

# Rotation settings for `vault write`, as key=value words.
rotation_args() {
  local id=$1 v
  v=$(cred "$id" rotation_period)
  [ -z "$v" ] || printf 'rotation_period=%s\n' "$v"
  v=$(cred "$id" rotation_schedule)
  [ -z "$v" ] || printf 'rotation_schedule=%s\n' "$v"
  v=$(cred "$id" rotation_policy)
  [ -z "$v" ] || printf 'rotation_policy=%s\n' "$v"
  v=$(cred "$id" rotate_on_read)
  [ -z "$v" ] || printf 'rotate_on_read=%s\n' "$v"
  v=$(cred "$id" rotate_on_read_cooldown)
  [ -z "$v" ] || printf 'rotate_on_read_cooldown=%s\n' "$v"
  return 0
}

onboard_os() {
  local id=$1 host account parent vars pw args=()
  host=$(cred "$id" host)
  account=$(cred "$id" account)
  parent=$(cred "$id" parent)
  pw=$(gen_password)
  vars=$(mktemp "${TMPDIR:-/tmp}/vdnc-onboard.XXXXXX")
  # shellcheck disable=SC2064
  trap "rm -f '$vars'" RETURN
  printf 'account: "%s"\npassword: "%s"\n' "$account" "$pw" >"$vars"
  "$VDNC_ROOT/scripts/ansible.sh" onboard.yml -e "target_host=$host" -e "@$vars" |
    grep -E "^$host .*failed=0" >/dev/null || {
    echo "onboard: Ansible could not set the initial password for $id" >&2
    return 1
  }
  rm -f "$vars"
  while IFS= read -r a; do args+=("$a"); done < <(rotation_args "$id")
  [ -z "$parent" ] || args+=("parent_account_ref=$parent")
  printf '%s' "$pw" | vault write "$(cred_config_path "$id")" username="$account" password=- "${args[@]}" >/dev/null
  unset pw
  vault write -f "$(cred_config_path "$id")/rotate" >/dev/null
  log "$id: onboarded ($(cred "$id" mode)), rotated once"
}

onboard_ldap() {
  local id=$1 dn account args=()
  dn=$(cred_dn "$id")
  account=$(cred "$id" account)
  while IFS= read -r a; do args+=("$a"); done < <(rotation_args "$id")
  vault write "$(cred_config_path "$id")" username="$account" dn="$dn" skip_import_rotation=false "${args[@]}" >/dev/null
  log "$id: onboarded (root-managed through cn=vault-rotator), rotated on import"
}

onboard_ldap_self() {
  local id=$1 dn account pw args=()
  dn=$(cred_dn "$id")
  account=$(cred "$id" account)
  pw=$(gen_password)
  printf '%s\n' "$pw" | podman exec -i vdnc-openldap sh -c \
    'read -r pw; ldappasswd -x -H ldap://localhost -D "cn=admin,dc=dance,dc=lab" -w "$(cat /run/secrets/ldap-admin-password)" -s "$pw" "$1" >/dev/null' sh "$dn"
  while IFS= read -r a; do args+=("$a"); done < <(rotation_args "$id")
  printf '%s' "$pw" | vault write "$(cred_config_path "$id")" username="$account" dn="$dn" password=- "${args[@]}" >/dev/null
  unset pw
  vault write -f "$(cred "$id" mount)/rotate-role/$account" >/dev/null
  log "$id: onboarded (self-managed), rotated once with its own password"
}

if [ "$reset" = true ]; then
  # Children first: a parent-managed account must go before its parent.
  for id in $(printf '%s\n' "$ids" | tac 2>/dev/null || printf '%s\n' "$ids" | tail -r); do
    if exists "$id"; then
      vault delete "$(cred_config_path "$id")" >/dev/null
      log "$id: removed from Vault"
    fi
  done
fi

created=0
for id in $ids; do
  if exists "$id"; then
    continue
  fi
  case "$(cred "$id" engine)/$(cred "$id" mount)" in
  os/*) onboard_os "$id" ;;
  ldap/ldap) onboard_ldap "$id" ;;
  ldap/ldap-self) onboard_ldap_self "$id" ;;
  esac
  created=$((created + 1))
done
log "$created credential(s) onboarded; $(($(wc -w <<<"$ids") - created)) already managed by Vault"
