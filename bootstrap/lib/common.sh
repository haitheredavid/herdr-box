# shellcheck shell=bash disable=SC2034 # STATE_DIR, arch, codename: used by bootstrap.sh and its phases
# herdr-box shared helpers, sourced by bootstrap.sh, its phases and dotfiles.sh.
# Sourcing has no side effects beyond setting the globals below.

# The bootstrap tree's parent (/opt/herdr-box on a box): bootstrap/, config/, box/.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE_DIR=/var/lib/herdr-box
arch=$(dpkg --print-architecture)
# shellcheck source=/dev/null
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
export DEBIAN_FRONTEND=noninteractive

say() { echo "herdr-box: $*"; }
die() {
    echo "herdr-box: $*" >&2
    exit 1
}

# Every mutation reports here, so a second run can prove it changed nothing.
changed() {
    say "changed: $*"
    if [ -n "${HERDR_BOX_CHANGES:-}" ] && [ -w "$HERDR_BOX_CHANGES" ]; then
        printf '%s\n' "$*" >>"$HERDR_BOX_CHANGES"
    fi
}

# install_if_changed MODE DST [SRC]: write SRC (default stdin) to DST with MODE, only
# when the content or mode differs. Returns 0 when it wrote, 1 when unchanged.
# Callers run under set -e, which doesn't apply in here (it's called in conditions),
# so every step checks itself.
install_if_changed() {
    local mode=$1 dst=$2 src tmp='' dir
    if [ $# -ge 3 ]; then
        src=$3
        [ -f "$src" ] || die "install_if_changed: missing $src"
    else
        tmp=$(mktemp) || die "install_if_changed: mktemp failed"
        cat >"$tmp" || die "install_if_changed: reading $dst content failed"
        src=$tmp
    fi
    if [ -f "$dst" ] && cmp -s "$src" "$dst" &&
        [ "$(stat -c %a "$dst")" = "$(printf '%o' "$((8#$mode))")" ]; then
        [ -z "$tmp" ] || rm -f "$tmp"
        return 1
    fi
    dir=$(dirname "$dst")
    [ -d "$dir" ] || install -d -m 755 "$dir" || die "cannot create $dir"
    install -m "$mode" "$src" "$dst" || die "cannot write $dst"
    [ -z "$tmp" ] || rm -f "$tmp"
    changed "$dst"
    return 0
}

# load_box_config DIR: source DIR/box.conf over defaults, validate, export.
load_box_config() {
    local dir=$1 home target p trusted re
    [ -f "$dir/box.conf" ] || die "missing $dir/box.conf (copy boxes/example/box.conf and edit it)"
    [ -f "$dir/authorized_keys" ] || die "missing $dir/authorized_keys (copy boxes/example/authorized_keys and edit it)"
    BOX_USER=
    BOX_SHELL=bash
    DOTFILES_REPOSITORY=
    DOTFILES_REF=
    # Kept unexpanded: callers expand it against the user's home.
    # shellcheck disable=SC2088
    DOTFILES_TARGET_PATH="~/dotfiles"
    DOTFILES_INSTALL_COMMAND=
    LLAMA_CPP_URL=
    EXTRA_APT_PACKAGES=
    MISE_TRUSTED_PATHS=
    # shellcheck source=/dev/null
    . "$dir/box.conf"

    [[ $BOX_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid BOX_USER '$BOX_USER' in $dir/box.conf"
    case $BOX_SHELL in bash | zsh) ;; *) die "BOX_SHELL must be bash or zsh, not '$BOX_SHELL'" ;; esac
    grep -Eq '^(ssh-|ecdsa-|sk-)' "$dir/authorized_keys" || die "$dir/authorized_keys has no SSH public key"

    # Remote URLs only: the box keeps its own checkout, never a path into the Mac's tree.
    [ -z "$DOTFILES_REPOSITORY" ] || [[ $DOTFILES_REPOSITORY =~ ^(https://|ssh://|git@)[^[:space:]]+$ ]] ||
        die "invalid DOTFILES_REPOSITORY '$DOTFILES_REPOSITORY' (want https://, ssh:// or git@; no file:// or paths)"
    [[ $DOTFILES_REF =~ ^[A-Za-z0-9._/-]*$ ]] && [[ $DOTFILES_REF != -* ]] ||
        die "invalid DOTFILES_REF '$DOTFILES_REF' (a branch, tag or sha)"
    [[ $DOTFILES_INSTALL_COMMAND =~ ^[A-Za-z0-9._/-]*$ ]] && [[ $DOTFILES_INSTALL_COMMAND != /* ]] &&
        [[ /$DOTFILES_INSTALL_COMMAND/ != */../* ]] ||
        die "invalid DOTFILES_INSTALL_COMMAND '$DOTFILES_INSTALL_COMMAND' (a path inside the repo)"

    # ~/projects may be the Mac's tree, bind-mounted: the checkout must not land there.
    target=$DOTFILES_TARGET_PATH
    re='^(~/|/)[A-Za-z0-9._/~-]+$'
    [[ $target =~ $re ]] && [[ /$target/ != */../* ]] ||
        die "invalid DOTFILES_TARGET_PATH '$target' (want ~/path or /path)"
    home=$(getent passwd "$BOX_USER" | cut -d: -f6) || true
    home=${home:-/home/$BOX_USER}
    target=${target/#\~/$home}
    while [[ $target == */ ]]; do target=${target%/}; done
    case $target in
        "$home" | "") die "DOTFILES_TARGET_PATH '$DOTFILES_TARGET_PATH' is the home itself" ;;
        "$home/projects" | "$home/projects/"*)
            die "DOTFILES_TARGET_PATH '$DOTFILES_TARGET_PATH' is under ~/projects (shared with the Mac); use e.g. ~/dotfiles"
            ;;
    esac

    [ -z "$LLAMA_CPP_URL" ] || [[ $LLAMA_CPP_URL =~ ^https?://[^[:space:]\"\'\$\`]+$ ]] ||
        die "invalid LLAMA_CPP_URL '$LLAMA_CPP_URL' in box.conf (want http://host:port)"
    [[ $EXTRA_APT_PACKAGES =~ ^[a-z0-9.+\ -]*$ ]] && [[ " $EXTRA_APT_PACKAGES" != *" -"* ]] ||
        die "invalid EXTRA_APT_PACKAGES '$EXTRA_APT_PACKAGES' (space-separated package names)"
    # Rendered into a sourced env file, so no quotes, spaces or expansions.
    re='^[A-Za-z0-9._/~:-]*$'
    [[ $MISE_TRUSTED_PATHS =~ $re ]] ||
        die "invalid MISE_TRUSTED_PATHS '$MISE_TRUSTED_PATHS' (colon-separated paths)"
    IFS=: read -ra trusted <<<"$MISE_TRUSTED_PATHS"
    for p in "${trusted[@]}"; do
        # shellcheck disable=SC2088 # matching a literal ~ from box.conf
        [[ $p == /* || $p == "~" || $p == "~/"* ]] ||
            die "invalid MISE_TRUSTED_PATHS entry '$p' (want an absolute or ~/ path)"
    done

    export BOX_USER BOX_SHELL DOTFILES_REPOSITORY DOTFILES_REF DOTFILES_TARGET_PATH \
        DOTFILES_INSTALL_COMMAND LLAMA_CPP_URL EXTRA_APT_PACKAGES MISE_TRUSTED_PATHS
}

# as_user CMD...: run as BOX_USER in its home with a clean environment plus the box env.
# fd 9 (the bootstrap lock) is closed so a daemon the command starts can't hold it.
as_user() {
    local home
    [ -n "${BOX_USER:-}" ] || die "as_user: BOX_USER is not set"
    home=$(getent passwd "$BOX_USER" | cut -d: -f6) || die "as_user: no account $BOX_USER"
    (cd "$home" && runuser -u "$BOX_USER" -- env -i HOME="$home" USER="$BOX_USER" LOGNAME="$BOX_USER" \
        SHELL=/bin/bash LANG=C.UTF-8 \
        PATH="$home/.local/bin:$home/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin" \
        MISE_YES=1 HERDR_BOX_CHANGES="${HERDR_BOX_CHANGES:-}" HERDR_BOX_ROOT="$root" \
        bash -c 'if [ -r /etc/herdr-box/env ]; then . /etc/herdr-box/env; fi; exec "$@"' herdr-box "$@" 9>&-)
}
