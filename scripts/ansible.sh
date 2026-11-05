#!/usr/bin/env bash
# scripts/ansible.sh <playbook> [ansible-playbook args...]
#
# The only supported way to run Ansible here. Runs from the repo root with
# ansible.cfg. Ansible refuses non-blocking stdio (agent shells, some CI), so
# stdin comes from /dev/null and output goes through cat.
set -euo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
playbook=${1:?Usage: ansible.sh <playbook> [args]}
shift
[ -f "ansible/$playbook" ] || {
  echo "ansible: unknown playbook ansible/$playbook" >&2
  exit 64
}
[ -s .secrets/ansible/id_ed25519 ] || {
  echo "ansible: no key at .secrets/ansible/id_ed25519. Run make hosts-build." >&2
  exit 1
}
[ -s .secrets/hosts/known_hosts ] || {
  echo "ansible: no .secrets/hosts/known_hosts. Run make hosts-keyscan." >&2
  exit 1
}
export ANSIBLE_CONFIG="$ROOT/ansible.cfg"
set -o pipefail
ansible-playbook "ansible/$playbook" "$@" </dev/null 2>&1 | cat
