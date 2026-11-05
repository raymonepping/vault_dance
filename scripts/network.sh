#!/bin/sh
# scripts/network.sh: create the shared network if it does not exist.
set -eu
podman network exists vdnc-internal || podman network create --label io.vdnc.project=vault_dance vdnc-internal >/dev/null
