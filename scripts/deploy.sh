#!/bin/sh
# Push bootstrap/ and config/ to a running box and re-run the bootstrap, without
# restarting it. Works for the container (over Tailscale) and for a dedicated
# Ubuntu 24.04 machine (first run included). Needs sudo on the box.
#
# Usage: scripts/deploy.sh <ssh-host>
#   HERDR_SSH_OPTS  extra ssh options (word-split), e.g. "-p 2298 -i key"
set -eu

[ $# -eq 1 ] || {
    echo "usage: scripts/deploy.sh <ssh-host>" >&2
    exit 2
}
host=$1
# shellcheck disable=SC2086,SC2029 # opts word-split on purpose; commands run remotely
s() { ssh ${HERDR_SSH_OPTS:-} "$host" "$@"; }
cd "$(dirname "$0")/.."

echo "==> uploading bundle to $host:/opt/herdr-box"
# Stage then swap, so a failed upload never leaves a half-written bundle.
tar --no-xattrs -czf - bootstrap config | s \
    'sudo -n sh -euc "rm -rf /opt/herdr-box.new && mkdir -p /opt/herdr-box.new && tar -xzf - -C /opt/herdr-box.new && rm -rf /opt/herdr-box && mv /opt/herdr-box.new /opt/herdr-box"'

echo "==> running bootstrap"
s 'sudo -n bash /opt/herdr-box/bootstrap/bootstrap.sh'
