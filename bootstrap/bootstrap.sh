#!/bin/bash
# herdr-box host bootstrap (Ubuntu 24.04, run as root). Idempotent: a second run
# changes nothing and reports "changes: 0". The same phases build the image, boot
# the container and set up a dedicated machine.
#
# Usage: bootstrap.sh [--box DIR] [--phases LIST] [--system]
#   --box DIR      this box's config dir: box.conf, authorized_keys, optional env
#                  (default: ../box next to bootstrap/, i.e. /opt/herdr-box/box)
#   --phases LIST  comma list of packages,system,host,user (default: all); they
#                  always run in that order
#   --system       alias for --phases packages,system (image build; no box config)
#
# Phases (bootstrap/phases/):
#   packages  apt repos (pinned keys), apt packages + EXTRA_APT_PACKAGES, mise binary
#   system    /etc/mise/conf.d, /etc/profile.d/herdr-box.sh, herdr wrappers, herdr-box-update
#   host      host keys on the state volume, sshd, box env, account, sudoers, shell
#   user      agent tools, dotfiles, mise toolchains, herdr integrations, tailscale report
#
# Callers: the Dockerfile (--phases packages, then --phases system),
# herdr-box-early.service (--phases host), herdr-box-bootstrap.service
# (--phases packages,system,user), deploy.sh and dedicated machines (all phases).
# Box config is required for host and user; packages-only/system-only runs read
# EXTRA_APT_PACKAGES from box.conf when present, else from the environment.
set -euo pipefail

# shellcheck source=lib/common.sh
. "$(dirname "$0")/lib/common.sh"

all_phases=(packages system host user)
box=$root/box
# shellcheck disable=SC2034 # read by phases/20-system.sh
config=$root/config
phases=packages,system,host,user
while [ $# -gt 0 ]; do
    case $1 in
        --box)
            [ $# -ge 2 ] || die "--box needs a directory"
            box=$2
            shift 2
            ;;
        --phases)
            [ $# -ge 2 ] || die "--phases needs a list"
            phases=$2
            shift 2
            ;;
        --system)
            phases=packages,system
            shift
            ;;
        -h | --help)
            awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
            exit 0
            ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

IFS=, read -ra wanted <<<"$phases"
[ ${#wanted[@]} -gt 0 ] || die "--phases is empty"
for p in "${wanted[@]}"; do
    case " ${all_phases[*]} " in *" $p "*) ;; *) die "unknown phase '$p' (want ${all_phases[*]})" ;; esac
done
selected=()
for p in "${all_phases[@]}"; do
    case ",$phases," in *",$p,"*) selected+=("$p") ;; esac
done
list=$(
    IFS=,
    echo "${selected[*]}"
)

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v apt-get >/dev/null || die "apt-get not found; this bootstrap targets Ubuntu 24.04"

# Boot, deploy and herdr-box-update may overlap; one bootstrap at a time.
mkdir -p /run
exec 9>>/run/herdr-box.lock
chmod 644 /run/herdr-box.lock
flock -w 600 9 || die "another bootstrap still holds /run/herdr-box.lock after 600s"

# World-writable so phases running as BOX_USER (as_user) can report changes too.
HERDR_BOX_CHANGES=$(mktemp /run/herdr-box-changes.XXXXXX)
chmod 666 "$HERDR_BOX_CHANGES"
export HERDR_BOX_CHANGES
trap 'rm -f "$HERDR_BOX_CHANGES"' EXIT

case ",$list," in
    *,host,* | *,user,*) load_box_config "$box" ;;
    *)
        # The image build has no box config; terraform passes EXTRA_APT_PACKAGES instead.
        EXTRA_APT_PACKAGES=${EXTRA_APT_PACKAGES:-}
        if [ -f "$box/box.conf" ]; then
            # shellcheck source=/dev/null
            EXTRA_APT_PACKAGES=$(
                EXTRA_APT_PACKAGES=
                . "$box/box.conf" >/dev/null
                printf '%s' "$EXTRA_APT_PACKAGES"
            )
        fi
        [[ $EXTRA_APT_PACKAGES =~ ^[a-z0-9.+\ -]*$ ]] && [[ " $EXTRA_APT_PACKAGES" != *" -"* ]] ||
            die "invalid EXTRA_APT_PACKAGES '$EXTRA_APT_PACKAGES' (space-separated package names)"
        ;;
esac

for p in "${selected[@]}"; do
    files=("$root"/bootstrap/phases/[0-9][0-9]-"$p".sh)
    [ -f "${files[0]}" ] || die "missing phase file bootstrap/phases/NN-$p.sh"
    # shellcheck source=/dev/null
    . "${files[0]}"
done

say "changes: $(wc -l <"$HERDR_BOX_CHANGES" | tr -d ' ')"
say "done: phases $list, arch $arch"
