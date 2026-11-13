#!/bin/sh
# Push bootstrap/, the shared config/ and one box's config dir (as box/) to a running
# box and re-run the bootstrap, without restarting it. Works for the container (over
# Tailscale) and for a dedicated Ubuntu 24.04 machine (first run included). Needs sudo
# on the box.
#
# Usage: scripts/deploy.sh <ssh-host> [box]   box: a dir under boxes/ (default: <ssh-host>)
#   HERDR_SSH_OPTS  extra ssh options (word-split), e.g. "-p 2298 -i key"
set -eu

[ $# -eq 1 ] || [ $# -eq 2 ] || {
    echo "usage: scripts/deploy.sh <ssh-host> [box]" >&2
    exit 2
}
host=$1
box=${2:-$1}
# shellcheck disable=SC2086,SC2029 # opts word-split on purpose; commands run remotely
s() { ssh ${HERDR_SSH_OPTS:-} "$host" "$@"; }
cd "$(dirname "$0")/.."

[ -f "boxes/$box/box.conf" ] || {
    echo "herdr-box: missing boxes/$box/box.conf (copy boxes/example to boxes/$box and edit it)" >&2
    exit 1
}

# The bundle's layout on the box: bootstrap/, config/ and box/ (this box's dir).
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -R bootstrap config "$stage/"
cp -R "boxes/$box" "$stage/box"

echo "==> uploading bundle (box $box) to $host:/opt/herdr-box"
# Stage then swap, so a failed upload never leaves a half-written bundle.
tar --no-xattrs -czf - -C "$stage" bootstrap config box | s \
    'sudo -n sh -euc "rm -rf /opt/herdr-box.new && mkdir -p /opt/herdr-box.new && tar -xzf - -C /opt/herdr-box.new && rm -rf /opt/herdr-box && mv /opt/herdr-box.new /opt/herdr-box"'

echo "==> running bootstrap"
s 'sudo -n bash /opt/herdr-box/bootstrap/bootstrap.sh'
