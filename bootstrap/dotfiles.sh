#!/bin/bash
# Set up BOX_USER's dotfiles. The bootstrap runs this as that user (as_user), with
# HERDR_BOX_ROOT and HERDR_BOX_CHANGES in the environment.
#
# Usage: dotfiles.sh <repo-url> <ref> <target-path> <install-command>
#   <target-path> is the checkout (a leading ~ means $HOME); never ~/projects.
#   <ref> is a branch, tag, or commit; empty means the remote's default branch.
#   The checkout moves to <ref> only when that loses nothing: a dirty tree or
#   commits not on origin keep it where it is, with a warning. A failed fetch keeps
#   the current checkout. Then <install-command> (an executable path inside the
#   repo; empty: the first of the Dev Containers / Codespaces names that exists)
#   runs from the repo root. It must be idempotent: this runs at every boot.
set -euo pipefail

if [ -n "${HERDR_BOX_ROOT:-}" ] && [ -f "$HERDR_BOX_ROOT/bootstrap/lib/common.sh" ]; then
    # shellcheck source=/dev/null
    . "$HERDR_BOX_ROOT/bootstrap/lib/common.sh"
else
    say() { echo "herdr-box: $*" >&2; }
    changed() {
        echo "herdr-box: changed: $*" >&2
        if [ -n "${HERDR_BOX_CHANGES:-}" ]; then echo "$*" >>"$HERDR_BOX_CHANGES"; fi
    }
fi

[ $# -eq 4 ] || {
    echo "usage: dotfiles.sh <repo-url> <ref> <target-path> <install-command>" >&2
    exit 2
}
url=$1
ref=$2
repo=$3
install=$4
# shellcheck disable=SC2088 # literal ~ on purpose
case $repo in
"~") repo=$HOME ;;
"~/"*) repo=$HOME/${repo#"~/"} ;;
esac
case ${repo%/}/ in
"$HOME/projects/"*)
    say "dotfiles: $repo is inside ~/projects; refusing"
    exit 1
    ;;
esac
g() { git -C "$repo" "$@"; }

if [ ! -d "$repo/.git" ]; then
    changed "dotfiles: cloning $url into $repo"
    mkdir -p "$(dirname "$repo")"
    git clone -q "$url" "$repo"
fi
# `git push box …` from another machine updates this working tree (when clean).
[ "$(g config --get receive.denyCurrentBranch || true)" = updateInstead ] ||
    g config receive.denyCurrentBranch updateInstead
origin=$(g remote get-url origin 2>/dev/null || true)
[ "$origin" = "$url" ] || say "dotfiles: origin is '$origin', not $url; fetching it anyway"

if g fetch -q --tags --prune origin; then
    if [ -z "$ref" ]; then
        g remote set-head origin --auto >/dev/null 2>&1 || true
        ref=$(g symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || true)
        ref=${ref#origin/}
        [ -n "$ref" ] || {
            say "dotfiles: cannot tell the default branch of $url; set the ref"
            exit 1
        }
    fi
    if g show-ref -q --verify "refs/remotes/origin/$ref"; then
        branch=$ref
        target=$(g rev-parse "refs/remotes/origin/$ref")
    elif target=$(g rev-parse -q --verify "$ref^{commit}" 2>/dev/null); then
        branch=
    else
        say "dotfiles: no branch, tag, or commit '$ref' in $url"
        exit 1
    fi
    head=$(g rev-parse -q --verify HEAD || true)
    current=$(g symbolic-ref -q --short HEAD || true)
    if [ "$head" = "$target" ] && [ "$current" = "$branch" ]; then
        : # already there
    elif [ -n "$(g status --porcelain)" ]; then
        say "dotfiles: staying at ${head:0:7}: $repo has local changes (wanted $ref ${target:0:7}):"
        g status --short >&2
    elif [ -n "$head" ] &&
        [ -n "$(g rev-list -n1 "$head" --not --remotes=origin --tags)" ]; then
        # HEAD has commits no remote ref or tag holds (on a branch or detached): moving
        # would orphan them.
        say "dotfiles: staying at ${head:0:7}: ${current:-HEAD} has commits not on origin (wanted $ref ${target:0:7})"
    elif [ -n "$branch" ]; then
        if [ -n "$current" ] && [ "$current" != "$branch" ] &&
            ! g merge-base --is-ancestor "refs/heads/$branch" "$target" 2>/dev/null &&
            g show-ref -q --verify "refs/heads/$branch"; then
            say "dotfiles: staying at ${head:0:7}: local branch $branch has commits not on origin/$branch"
        else
            changed "dotfiles: updating to $branch (${target:0:7})"
            g checkout -q -B "$branch" "$target"
            g branch -q --set-upstream-to="origin/$branch" "$branch"
        fi
    else
        changed "dotfiles: updating to $ref (${target:0:7})"
        g checkout -q --detach "$target"
    fi
else
    say "dotfiles: fetch failed; keeping the checkout at $(g rev-parse --short HEAD 2>/dev/null || echo '?')"
fi

if [ -n "$install" ]; then
    [ -f "$repo/$install" ] && [ -x "$repo/$install" ] || {
        say "dotfiles: $repo has no executable $install"
        exit 1
    }
else
    for c in install.sh install bootstrap.sh bootstrap script/bootstrap setup.sh setup script/setup; do
        if [ -f "$repo/$c" ] && [ -x "$repo/$c" ]; then
            install=$c
            break
        fi
    done
    [ -n "$install" ] || {
        say "dotfiles: no install script in $repo; nothing to run"
        exit 0
    }
fi
cd "$repo"
"./$install"
