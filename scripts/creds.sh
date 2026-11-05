#!/usr/bin/env bash
# scripts/creds.sh: shared helpers for the credentials in
# config/credentials.json. Source, do not execute (after common.sh).

VDNC_CREDS="$VDNC_ROOT/config/credentials.json"
VDNC_BASE_DN="dc=dance,dc=lab"

# Ids, in file order (parents before the accounts they manage).
cred_ids() { jq -r '.credentials[].id' "$VDNC_CREDS"; }
cred() { jq -r --arg id "$1" --arg k "$2" '.credentials[] | select(.id == $id) | .[$k] // empty' "$VDNC_CREDS"; }
cred_dn() { printf 'cn=%s,ou=service-accounts,%s' "$(cred "$1" account)" "$VDNC_BASE_DN"; }

# The Vault path of a credential's configuration and of its current secret.
cred_config_path() {
  case "$(cred "$1" engine)" in
  os) printf '%s/hosts/%s/accounts/%s' "$(cred "$1" mount)" "$(cred "$1" host)" "$(cred "$1" account)" ;;
  ldap) printf '%s/static-role/%s' "$(cred "$1" mount)" "$(cred "$1" account)" ;;
  esac
}
cred_secret_path() {
  case "$(cred "$1" engine)" in
  os) printf '%s/creds' "$(cred_config_path "$1")" ;;
  ldap) printf '%s/static-cred/%s' "$(cred "$1" mount)" "$(cred "$1" account)" ;;
  esac
}
cred_rotation_id() { cred_config_path "$1"; }

ssh_port_of() {
  case "$1" in
  host-rocky) vdnc_conf VDNC_PORT_SSH_ROCKY ;;
  host-ubuntu) vdnc_conf VDNC_PORT_SSH_UBUNTU ;;
  esac
}

gen_password() { # 24 characters the initial-password path accepts everywhere
  openssl rand -base64 30 | tr -d '/+=\n' | cut -c1-22 | sed 's/$/A7/'
}

# PASS or FAIL: log in over SSH with a password read from stdin. The host key
# must match .secrets/hosts/known_hosts; the password never reaches argv.
ssh_login() { # <host> <user>  (password on stdin)
  local pw out
  IFS= read -r pw || true
  if out=$(sshpass -d 3 ssh -o BatchMode=no -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
    -o UserKnownHostsFile="$VDNC_ROOT/.secrets/hosts/known_hosts" -o StrictHostKeyChecking=yes \
    -o ConnectTimeout=5 -p "$(ssh_port_of "$1")" "$2@127.0.0.1" 'id -un' 3<<<"$pw" </dev/null 2>&1); then
    [ "$out" = "$2" ] && echo PASS && return 0
  fi
  echo "FAIL"
  return 1
}

# PASS or FAIL: an LDAP simple bind as <dn> with a password read from stdin,
# inside the openldap container (the directory is not published to the Mac).
ldap_bind() { # <dn>  (password on stdin)
  if podman exec -i vdnc-openldap sh -c 'umask 077; f=$(mktemp); tr -d "\n" >"$f"; ldapwhoami -x -H ldap://localhost -D "$1" -y "$f" >/dev/null 2>&1; rc=$?; rm -f "$f"; exit $rc' sh "$1"; then
    echo PASS
  else
    echo FAIL
    return 1
  fi
}

# Orphaned rotation ids, one per line. Only the active node answers.
orphans() {
  vault_active >/dev/null 2>&1 || return 0
  curl -s --cacert "$VAULT_CACERT" -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/rotation/orphans" |
    jq -r '.data.orphans // [] | .[]' 2>/dev/null || true
}

# The state the console shows (api/lib/credentials.js deriveState), in bash:
# ok | overdue | orphaned | recovered | on-read | manual | missing.
# Needs VAULT_ADDR on the active node and a token; pass the orphan list.
cred_state() { # <id> <orphan list>
  local cfg next now listed=no
  cfg=$(vault read -format=json "$(cred_config_path "$1")" 2>/dev/null) || {
    echo missing
    return
  }
  grep -qxF "$(cred_rotation_id "$1")" <<<"$2" && listed=yes
  if ! jq -e '.data | ((.rotation_schedule // "") != "") or ((.rotation_period // 0) > 0)' <<<"$cfg" >/dev/null; then
    jq -e '.data.rotate_on_read' <<<"$cfg" >/dev/null && echo on-read || echo manual
    return
  fi
  next=$(jq -r '.data.next_vault_rotation // empty' <<<"$cfg")
  next=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "${next%.*}Z" +%s 2>/dev/null || echo 0)
  now=$(date -u +%s)
  if [ "$next" -gt $((now - 15)) ]; then
    [ "$listed" = yes ] && echo recovered || echo ok
  else
    [ "$listed" = yes ] && echo orphaned || echo overdue
  fi
}

# The credential's version (OS) or last rotation time (LDAP): what changes
# when Vault rotates it.
cred_mark() {
  vault read -format=json "$(cred_config_path "$1")" 2>/dev/null |
    jq -r '.data.current_version // .data.last_vault_rotation // "-"'
}
