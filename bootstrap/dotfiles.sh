#!/bin/bash
# Set up BOX_USER's dotfiles. The bootstrap runs this as that user after their tools
# are installed (mise shims on PATH), when box.conf sets DOTFILES_REPO.
#
# Usage: dotfiles.sh <repo-url> <setup-path>
#   The repo lives at ~/projects/dotfiles. A fresh home built on a dotfiles base
#   image (terraform dotfiles_dir) already has it; a home without it is seeded from
#   the base image's /opt/dotfiles (the checkout the image was built from, pushed or
#   not), else cloned from <repo-url>. Then <setup-path>, relative to the repo,
#   runs; it must be idempotent, since this runs at every boot.
set -euo pipefail

[ $# -eq 2 ] || {
    echo "usage: dotfiles.sh <repo-url> <setup-path>" >&2
    exit 2
}
url=$1
setup=$2
repo=$HOME/projects/dotfiles

if [ ! -d "$repo/.git" ]; then
    mkdir -p "$(dirname "$repo")"
    if [ -d /opt/dotfiles/.git ]; then
        echo "herdr-box: dotfiles: seeding $repo from /opt/dotfiles" >&2
        cp -R /opt/dotfiles "$repo"
    else
        echo "herdr-box: dotfiles: cloning $url" >&2
        git clone -q "$url" "$repo"
    fi
fi
[ -x "$repo/$setup" ] || {
    echo "herdr-box: $repo has no executable $setup (DOTFILES_SETUP); pull a version that has it" >&2
    exit 1
}
"$repo/$setup"
