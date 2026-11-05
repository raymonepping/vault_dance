#!/usr/bin/env bash
# scripts/hosts-verify.sh: each lab host has the configuration Ansible owns.
# Asks the host itself through podman exec; changes nothing.
set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "$0")/common.sh"

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
on() { podman exec "$c" "$@"; }

for d in rocky ubuntu; do
  c="vdnc-host-$d"
  echo "host-$d"
  if [ "$(vdnc_container_state "$c")" != running ]; then
    bad "$c is not running (make hosts-up)"
    continue
  fi
  on pgrep -x sshd >/dev/null && ok "sshd runs" || bad "sshd runs"
  for u in mgmt-vault app-deploy ops-breakglass; do
    if on id "$u" >/dev/null 2>&1; then ok "user $u exists"; else bad "user $u exists (make hosts-configure)"; fi
  done
  rules=$(on sudo -l -U mgmt-vault 2>/dev/null | sed -n '/may run the following/,$p' | tail -n +2 | sed 's/^ *//')
  if [ "$rules" = "(root) NOPASSWD: /usr/sbin/chpasswd" ]; then
    ok "mgmt-vault may run exactly chpasswd as root"
  else
    bad "mgmt-vault sudo rights: '${rules:-none}'"
  fi
  rules=$(on sudo -l -U app-deploy 2>/dev/null | grep -c NOPASSWD || true)
  [ "$rules" = 0 ] && ok "app-deploy has no sudo rights" || bad "app-deploy has sudo rights"
  for u in mgmt-vault app-deploy ops-breakglass; do
    t=$(on /usr/sbin/sshd -T -C "user=$u,host=vault-1,addr=10.89.0.10" 2>/dev/null)
    if grep -qx 'passwordauthentication yes' <<<"$t" && grep -qx 'permittty yes' <<<"$t"; then
      ok "sshd: $u may log in with a password and gets a PTY"
    else
      bad "sshd: $u password login or PTY missing"
    fi
  done
  t=$(on /usr/sbin/sshd -T -C "user=ansible,host=mac,addr=10.89.0.1" 2>/dev/null)
  grep -qx 'passwordauthentication no' <<<"$t" && ok "sshd: ansible is key-only" || bad "sshd: ansible accepts passwords"
  t=$(on /usr/sbin/sshd -T -C "user=root,host=mac,addr=10.89.0.1" 2>/dev/null)
  grep -qx 'permitrootlogin no' <<<"$t" && ok "sshd: root may not log in" || bad "sshd: root may log in"
  for u in mgmt-vault app-deploy ops-breakglass; do
    min=$(on chage -l "$u" 2>/dev/null | awk -F': ' '/Minimum number of days/ {print $2}')
    [ "$min" = 0 ] && ok "$u: no minimum password age" || bad "$u: minimum password age is '$min' (scenario-password-age active?)"
  done
done
echo
echo "hosts-verify: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
