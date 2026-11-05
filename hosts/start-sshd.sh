#!/bin/sh
# start-sshd: PID 1 of a lab host. Host keys are created once, in the
# container layer, on first start (not baked into the image).
set -eu
ssh-keygen -A >/dev/null
mkdir -p /run/sshd
# No systemd here: nothing removes pam_nologin's flag after "boot".
rm -f /run/nologin /etc/nologin /var/run/nologin
exec /usr/sbin/sshd -D -e
