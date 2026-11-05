#!/usr/bin/env bash
# scripts/probe.sh: prove every Vault call the lab depends on against the live
# cluster, on scratch mounts (probe-os/, probe-ldap/, probe-ldap-self/),
# scratch host accounts (probe-*) and scratch directory entries (cn=probe-*).
# Nothing the lab manages is touched. Everything is removed afterwards.
# Writes docs/capabilities.md: call, expected, Vault's answer, match.
#
# Never prints a password: fingerprints (first 8 hex of SHA-256) only.
# Operator token. Takes about a minute.
set -euo pipefail
umask 077
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"
# shellcheck source=scripts/creds.sh
source "$VDNC_ROOT/scripts/creds.sh"
cd "$VDNC_ROOT"

B=$VDNC_BASE_DN
OUT="$VDNC_ROOT/docs/capabilities.md"
ROWS=$(mktemp)
VARS=$(mktemp "${TMPDIR:-/tmp}/vdnc-probe.XXXXXX")
trap 'rm -f "$ROWS" "$VARS"' EXIT
pass=0
fail=0

row() { # <area> <call> <expected> <answer> <match yes|no>
  printf '| %s | `%s` | %s | %s | %s |\n' "$1" "$2" "$3" "$(tr '|\n' '/ ' <<<"$4" | cut -c1-160)" "$5" >>"$ROWS"
  if [ "$5" = yes ]; then
    pass=$((pass + 1))
    printf '  \033[32m✓\033[0m %s: %s\n' "$1" "$2"
  else
    fail=$((fail + 1))
    printf '  \033[31m✗\033[0m %s: %s (%s)\n' "$1" "$2" "$4"
  fi
}
expect_ok() { # <area> <call> <expected> <command...>
  local area=$1 call=$2 want=$3 out
  shift 3
  if out=$("$@" 2>&1); then row "$area" "$call" "$want" "${out:-success (no body)}" yes; else row "$area" "$call" "$want" "$out" no; fi
}
expect_err() { # <area> <call> <expected> <pattern> <command...>
  local area=$1 call=$2 want=$3 pat=$4 out
  shift 4
  if out=$("$@" 2>&1); then
    row "$area" "$call" "$want" "accepted: ${out:-no body}" no
    return
  fi
  # Match Vault's own error lines ("* ..."), never the request echo.
  local errs
  errs=$(grep -E '^[[:space:]]*\*' <<<"$out" | sed 's/^[*[:space:]]*//' || true)
  [ -n "$errs" ] || errs=$out
  if grep -qiE "$pat" <<<"$errs"; then
    row "$area" "$call" "$want" "$(grep -iE "$pat" <<<"$errs" | head -1)" yes
  else
    row "$area" "$call" "$want" "$errs" no
  fi
}
v() { vault "$@"; }
gen() { gen_password; }
ldap_admin() { podman exec -i vdnc-openldap sh -c "$1"; }

cleanup() {
  vault_active >/dev/null 2>&1 || return 0
  vault_token operator >/dev/null 2>&1 || return 0
  for m in probe-os probe-ldap probe-ldap-self; do v secrets disable "$m" >/dev/null 2>&1 || true; done
  v delete sys/policies/rotation/probe-quick >/dev/null 2>&1 || true
  for h in host-rocky host-ubuntu; do
    "$VDNC_ROOT/scripts/ansible.sh" probe-accounts.yml -e "target_host=$h" -e state=absent >/dev/null 2>&1 || true
  done
  for cn in probe-root probe-root2 probe-self; do
    ldap_admin "ldapdelete -x -H ldap://localhost -D cn=admin,$B -w \"\$(cat /run/secrets/ldap-admin-password)\" cn=$cn,ou=service-accounts,$B >/dev/null 2>&1" || true
  done
}

echo "probe: cleaning leftovers of an earlier run"
cleanup
vault_active
vault_token operator
version=$(vdnc_conf VDNC_OS_PLUGIN_VERSION)

echo "probe: cluster"
for n in $VDNC_CLUSTER_NODES; do
  vault_node "$n"
  if curl -sf --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/leader" | jq -e '.is_self' >/dev/null; then
    a=$(curl -s --cacert "$VAULT_CACERT" -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/rotation/orphans")
    row rotation "GET sys/rotation/orphans ($n, active)" "answers" "$(jq -c '.data // .errors' <<<"$a")" "$(jq -e '.data' <<<"$a" >/dev/null && echo yes || echo no)"
  else
    a=$(curl -s --cacert "$VAULT_CACERT" -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/sys/rotation/orphans")
    row rotation "GET sys/rotation/orphans ($n, perf standby)" "refused: only the active node runs the rotation manager" "$(jq -r '.errors[0] // "answered"' <<<"$a" | tr -d '\n\t')" "$(grep -q 'not initialized' <<<"$a" && echo yes || echo no)"
  fi
done
vault_active

echo "probe: rotation policies"
expect_ok rotation "POST sys/policies/rotation/probe-quick" "created (2 x 2)" v write sys/policies/rotation/probe-quick max_retries_per_cycle=2 max_retry_cycles=2
expect_ok rotation "GET sys/policies/rotation/probe-quick" "both fields" bash -c 'vault read -format=json sys/policies/rotation/probe-quick | jq -ec ".data | select(.max_retries_per_cycle == 2 and .max_retry_cycles == 2)"'
expect_err rotation "LIST sys/policies/rotation" "no list endpoint in 2.2.1 (the API reads policies by name)" "unsupported path" bash -c 'curl -sf --cacert "$VAULT_CACERT" -H "X-Vault-Token: $VAULT_TOKEN" -X LIST "$VAULT_ADDR/v1/sys/policies/rotation" || { curl -s --cacert "$VAULT_CACERT" -H "X-Vault-Token: $VAULT_TOKEN" -X LIST "$VAULT_ADDR/v1/sys/policies/rotation" | jq -r ".errors[]" | sed "s/^/* /"; exit 1; }'
expect_err rotation "POST sys/policies/rotation/probe-bad (no fields)" "refused: both fields are required" "required|missing|must" v write sys/policies/rotation/probe-bad max_retry_cycles=2

echo "probe: OS secrets engine"
expect_ok os "GET sys/plugins/catalog/secret/vault-plugin-secrets-os" "v$version registered" bash -c "vault plugin info -format=json -version=v$version secret vault-plugin-secrets-os | jq -r '.version'"
expect_ok os "POST sys/mounts/probe-os (plugin)" "mounted" v secrets enable -path=probe-os -plugin-version="v$version" vault-plugin-secrets-os
expect_ok os "POST probe-os/config" "TOFU off, 5 versions" v write probe-os/config max_versions=5 ssh_host_key_trust_on_first_use=false
P1=$(gen)
P2=$(gen)
P3=$(gen)
printf 'passwords:\n  probe-parent: "%s"\n  probe-child: "%s"\n  probe-self: "%s"\n' "$P1" "$P2" "$P3" >"$VARS"
for h in host-rocky host-ubuntu; do
  "$VDNC_ROOT/scripts/ansible.sh" probe-accounts.yml -e "target_host=$h" -e state=present -e "@$VARS" >/dev/null
done
: >"$VARS"
for h in host-rocky host-ubuntu; do
  expect_ok os "POST probe-os/hosts/$h (ssh_host_key pinned)" "created" v write "probe-os/hosts/$h" address="$h" port=22 ssh_host_key="$(cat ".secrets/hosts/$h.pub")"
  expect_ok os "POST probe-os/hosts/$h/accounts/probe-parent" "created; verify_connection logs in" env P="$P1" A="probe-os/hosts/$h/accounts/probe-parent" bash -c 'printf "%s" "$P" | vault write "$A" username=probe-parent password=-'
  expect_ok os "POST probe-os/hosts/$h/accounts/probe-child (parent_account_ref)" "created" env P="$P2" A="probe-os/hosts/$h/accounts/probe-child" bash -c 'printf "%s" "$P" | vault write "$A" username=probe-child parent_account_ref=probe-parent password=- rotation_policy=probe-quick'
  expect_ok os "POST probe-os/hosts/$h/accounts/probe-self (self-managed)" "created" env P="$P3" A="probe-os/hosts/$h/accounts/probe-self" bash -c 'printf "%s" "$P" | vault write "$A" username=probe-self password=-'
done
unset P1 P2 P3
expect_ok os "rotation_policy on an OS account (open question 3)" "stored and read back" bash -c 'vault read -format=json probe-os/hosts/host-rocky/accounts/probe-child | jq -er ".data.rotation_policy | select(. == \"probe-quick\")"'
expect_err os "POST probe-os/hosts/probe-wrongkey/accounts/x (other host's key)" "refused: pinned host key does not match" "host key|mismatch|knownhosts|handshake|key mismatch|unable to verify" bash -c "vault write probe-os/hosts/probe-wrongkey address=host-rocky port=22 ssh_host_key=\"\$(cat .secrets/hosts/host-ubuntu.pub)\" >/dev/null && printf '%s' 'x' | vault write probe-os/hosts/probe-wrongkey/accounts/x username=probe-self password=-"
for h in host-rocky host-ubuntu; do
  for a in probe-parent probe-child probe-self; do
    expect_ok os "POST probe-os/hosts/$h/accounts/$a/rotate" "rotated" v write -f "probe-os/hosts/$h/accounts/$a/rotate"
    s=$(v read -format=json "probe-os/hosts/$h/accounts/$a/creds")
    pw=$(jq -r .data.password <<<"$s")
    res=$(printf '%s\n' "$pw" | ssh_login "$h" "$a" || true)
    what="SSH login with Vault's password"
    [ "$h/$a" = host-ubuntu/probe-self ] && what="$what (open question 4: self-managed on Ubuntu)"
    row os "GET probe-os/hosts/$h/accounts/$a/creds + SSH" "$what: PASS" "v$(jq -r .data.version <<<"$s"), fp $(fingerprint "$pw"), $res" "$([ "$res" = PASS ] && echo yes || echo no)"
    unset pw s
  done
done
expect_ok os "GET probe-os/hosts/host-rocky/accounts/probe-child/versions" "version history" bash -c 'vault read -format=json probe-os/hosts/host-rocky/accounts/probe-child/versions | jq -c ".data | {current_version, oldest_version, versions: (.versions | keys)}"'
expect_ok os "POST …/probe-child/versions/1/restore" "Vault's record only" v write -f probe-os/hosts/host-rocky/accounts/probe-child/versions/1/restore
pw=$(v read -field=password probe-os/hosts/host-rocky/accounts/probe-child/creds)
res=$(printf '%s\n' "$pw" | ssh_login host-rocky probe-child || true)
unset pw
row os "SSH login after restore" "FAIL: restore does not touch the host" "$res" "$([ "$res" = FAIL ] && echo yes || echo no)"
expect_ok os "POST …/probe-child/rotate after restore" "the parent sets a new password again" v write -f probe-os/hosts/host-rocky/accounts/probe-child/rotate
pw=$(v read -field=password probe-os/hosts/host-rocky/accounts/probe-child/creds)
res=$(printf '%s\n' "$pw" | ssh_login host-rocky probe-child || true)
unset pw
row os "SSH login after the next rotation" "PASS" "$res" "$([ "$res" = PASS ] && echo yes || echo no)"
expect_ok os "POST …/probe-child (rotation_period=30)" "next_vault_rotation set" bash -c 'vault write probe-os/hosts/host-rocky/accounts/probe-child rotation_period=30 >/dev/null && vault read -format=json probe-os/hosts/host-rocky/accounts/probe-child | jq -er ".data.next_vault_rotation"'

echo "probe: LDAP secrets engine"
for cn in probe-root probe-self; do
  ldap_admin "ldapadd -x -H ldap://localhost -D cn=admin,$B -w \"\$(cat /run/secrets/ldap-admin-password)\" >/dev/null" <<LDIF
dn: cn=$cn,ou=service-accounts,$B
objectClass: inetOrgPerson
cn: $cn
sn: probe
LDIF
done
expect_ok ldap "POST sys/mounts/probe-ldap" "mounted" v secrets enable -path=probe-ldap ldap
rot=$(v kv get -mount=kv -field=value dance/identity/system/vault-rotator)
expect_ok ldap "POST probe-ldap/config (binddn vault-rotator)" "configured" env P="$rot" B="$B" bash -c 'printf "%s" "$P" | vault write probe-ldap/config binddn="cn=vault-rotator,ou=system,$B" bindpass=- url=ldap://openldap:389 userdn="ou=service-accounts,$B" schema=openldap'
unset rot
expect_ok ldap "POST probe-ldap/static-role/probe-root" "imported and rotated" v write probe-ldap/static-role/probe-root username=probe-root dn="cn=probe-root,ou=service-accounts,$B" rotation_period=60
s=$(v read -format=json probe-ldap/static-cred/probe-root)
pw=$(jq -r .data.password <<<"$s")
res=$(printf '%s' "$pw" | ldap_bind "cn=probe-root,ou=service-accounts,$B" || true)
row ldap "GET probe-ldap/static-cred/probe-root + bind" "PASS" "fp $(fingerprint "$pw"), $res" "$([ "$res" = PASS ] && echo yes || echo no)"
unset pw s
expect_ok ldap "POST sys/mounts/probe-ldap-self" "mounted" v secrets enable -path=probe-ldap-self ldap
expect_ok ldap "POST probe-ldap-self/config (self_managed=true, no bindpass)" "configured" v write probe-ldap-self/config self_managed=true url=ldap://openldap:389 userdn="ou=service-accounts,$B" schema=openldap
selfpw=$(gen)
printf '%s\n' "$selfpw" | ldap_admin "read -r pw; ldappasswd -x -H ldap://localhost -D cn=admin,$B -w \"\$(cat /run/secrets/ldap-admin-password)\" -s \"\$pw\" cn=probe-self,ou=service-accounts,$B"
expect_err ldap "POST probe-ldap-self/static-role/probe-self (no password)" "refused: self-managed needs the current password" "password" v write probe-ldap-self/static-role/probe-self username=probe-self dn="cn=probe-self,ou=service-accounts,$B" rotation_period=60
expect_ok ldap "POST probe-ldap-self/static-role/probe-self (dn + password)" "imported and rotated with its own password" env P="$selfpw" B="$B" bash -c 'printf "%s" "$P" | vault write probe-ldap-self/static-role/probe-self username=probe-self dn="cn=probe-self,ou=service-accounts,$B" password=- rotation_period=60'
unset selfpw
s=$(v read -format=json probe-ldap-self/static-cred/probe-self)
pw=$(jq -r .data.password <<<"$s")
res=$(printf '%s' "$pw" | ldap_bind "cn=probe-self,ou=service-accounts,$B" || true)
row ldap "GET probe-ldap-self/static-cred/probe-self + bind" "PASS" "fp $(fingerprint "$pw"), $res" "$([ "$res" = PASS ] && echo yes || echo no)"
unset pw s
expect_ok ldap "POST probe-ldap/static-role/probe-root/health-check/exec" "healthy" bash -c 'vault write -format=json -f probe-ldap/static-role/probe-root/health-check/exec | jq -ec ".data | select(.healthy) | {healthy, reason, type: .health_checks[0].type}"'
expect_ok ldap "GET probe-ldap/static-role/probe-root/health-check/last" "cached result" bash -c 'vault read -format=json probe-ldap/static-role/probe-root/health-check/last | jq -ec ".data.last_result | {healthy, reason}"'
expect_ok ldap "POST probe-ldap/config/health-check/exec" "bind as vault-rotator works" bash -c 'vault write -format=json -f probe-ldap/config/health-check/exec | jq -ec ".data | select(.healthy) | .health_checks[0].reason"'
expect_ok ldap "POST probe-ldap-self/static-role/probe-self/health-check/exec" "healthy" bash -c 'vault write -format=json -f probe-ldap-self/static-role/probe-self/health-check/exec | jq -ec ".data | select(.healthy) | .reason"'
expect_err ldap "PUT probe-ldap/static-role/probe-root/unlock" "refused: Active Directory only" "not supported|schema" v write -f probe-ldap/static-role/probe-root/unlock
v write probe-ldap/static-role/probe-root rotation_period=0 rotate_on_read=true rotate_on_read_cooldown=15 >/dev/null
sleep 16 # the cooldown counts from the last rotation, and the role rotated recently
a=$(v read -format=json probe-ldap/static-cred/probe-root)
b=$(v read -format=json probe-ldap/static-cred/probe-root)
fa=$(fingerprint "$(jq -r .data.password <<<"$a")")
fb=$(fingerprint "$(jq -r .data.password <<<"$b")")
row ldap "GET probe-ldap/static-cred/probe-root twice (rotate_on_read, cooldown 15s)" "first rotates, second inside the cooldown does not" "rotated_on_read $(jq .data.rotated_on_read <<<"$a") then $(jq .data.rotated_on_read <<<"$b"); fp $fa then $fb" \
  "$([ "$(jq .data.rotated_on_read <<<"$a")" = true ] && [ "$(jq .data.rotated_on_read <<<"$b")" = false ] && [ "$fa" = "$fb" ] && echo yes || echo no)"
unset a b
expect_ok ldap "POST probe-ldap/static-role/probe-root (rotation_schedule */5)" "next on a 5-minute boundary" bash -c 'vault write probe-ldap/static-role/probe-root rotate_on_read=false rotation_schedule="*/5 * * * *" >/dev/null && vault read -format=json probe-ldap/static-role/probe-root | jq -er ".data.next_vault_rotation | select(test(\":[0-5][05]:00Z$\"))"'
expect_err ldap "POST probe-ldap/static-role/probe-root (period and schedule)" "refused: one or the other" "cannot|both|mutually|only one" v write probe-ldap/static-role/probe-root rotation_period=60 rotation_schedule="*/5 * * * *"
expect_ok ldap "rotation_policy on an LDAP static role" "stored" bash -c 'vault write probe-ldap/static-role/probe-root rotation_policy=probe-quick >/dev/null && vault read -format=json probe-ldap/static-role/probe-root | jq -er ".data.rotation_policy | select(. == \"probe-quick\")"'

echo "probe: cleaning up"
cleanup
unset VAULT_TOKEN

{
  cat <<EOF
# What Vault 2.2.1 answered

Written by \`make probe\` on $(date -u +%Y-%m-%d) against the live cluster
(vault-plugin-secrets-os v$version). Scratch mounts, scratch accounts and
scratch directory entries only; all removed afterwards. Secrets appear as
fingerprints (first 8 hex of SHA-256).

Result: **$pass matched, $fail did not.**

| Area | Call | Expected | Vault's answer | Match |
| --- | --- | --- | --- | --- |
EOF
  cat "$ROWS"
  cat <<'EOF'

## Measured by hand (prompt 05), not by this probe

These take minutes and change the scenario accounts' state, so `make probe`
does not repeat them; `make rotation-test` exercises them end to end.

- **Time to orphan, LDAP root-managed** (`rotation_period=30`, policy 2 x 2,
  rotator's write rule removed): listed in `sys/rotation/orphans` 177s after
  the break. Attempts: 3 in the first cycle (10s, then 20s apart), 3 in the
  second, one more, then none.
- **OS accounts did not follow their rotation policy** (plugin 0.2.2+ent).
  With `rotation_policy=probe-quick` (2 x 2) on the account, later also on the
  host, the parent locked: 24 attempts in 27 minutes, in cycles of 7 (the
  first plus 6 retries, Vault's default per cycle), backoff 15s doubling to
  about 3 minutes, and no entry in `sys/rotation/orphans`. The policy is
  stored and read back, but not applied. Vault keeps retrying; that the account
  heals by itself once the host accepts the login again is what make
  rotation-test checks (scenario host-down).
- **An orphan record outlives the fix.** Re-writing the role (the documented
  restore), deleting and recreating it, and a leader change all left the
  entry in `sys/rotation/orphans`, while the role rotated on schedule again.
  Disabling the mount does not remove it either: the probe's own scratch
  roles stay listed after `make probe` removed their mounts. The lab
  therefore calls a credential orphaned only when it is listed AND its
  `next_vault_rotation` is in the past.
- **The rotation error is only in the active node's log** (`rotation-job-manager:
  rotation failed, attempting to re-queue: rotationID=… error="…"`). An account
  or role read shows no error field; `next_vault_rotation` stays in the past
  while Vault retries.
EOF
} >"$OUT"
chmod 644 "$OUT"
echo
echo "probe: $pass matched, $fail did not. Written to docs/capabilities.md"
[ "$fail" -eq 0 ]
