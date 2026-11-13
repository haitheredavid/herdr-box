# shellcheck shell=bash disable=SC2154 # root, box: set by bootstrap.sh
# Phase host: sourced by bootstrap.sh after lib/common.sh and load_box_config.
# Runs early (herdr-box-early.service), offline, before sshd and tailscaled start:
# host keys, sshd, the account, /etc/herdr-box/env, git safe.directory.

u=$BOX_USER

# --- host keys -----------------------------------------------------------------------
# The image ships none. They live in STATE_DIR (a volume in the container), so a
# replaced box keeps its identity; a dedicated machine adopts its existing keys.
key_types=(ed25519 ecdsa rsa)
install -d -m 700 "$STATE_DIR/ssh"
if ! compgen -G "$STATE_DIR/ssh/ssh_host_*_key" >/dev/null && [ -f /etc/ssh/ssh_host_ed25519_key ]; then
    for t in "${key_types[@]}"; do
        [ -f "/etc/ssh/ssh_host_${t}_key" ] || continue
        cp -p "/etc/ssh/ssh_host_${t}_key" "/etc/ssh/ssh_host_${t}_key.pub" "$STATE_DIR/ssh/"
    done
    changed "sshd: copied host keys from /etc/ssh to $STATE_DIR/ssh"
fi
for t in "${key_types[@]}"; do
    key=$STATE_DIR/ssh/ssh_host_${t}_key
    [ -f "$key" ] && continue
    rm -f "$key.pub"
    ssh-keygen -q -t "$t" -N '' -C "root@$(hostname)" -f "$key"
    changed "sshd: generated $t host key"
done
# Tailscale SSH presents /etc/ssh's host keys when they exist and generates its own
# otherwise; mirror ours there so both doors keep one identity. (This phase runs
# before tailscaled starts.)
for t in "${key_types[@]}"; do
    install_if_changed 600 "/etc/ssh/ssh_host_${t}_key" "$STATE_DIR/ssh/ssh_host_${t}_key" || true
    install_if_changed 644 "/etc/ssh/ssh_host_${t}_key.pub" "$STATE_DIR/ssh/ssh_host_${t}_key.pub" || true
done

# --- sshd ----------------------------------------------------------------------------
reload_ssh=0
install_if_changed 644 "/etc/ssh/authorized_keys/$u" "$box/authorized_keys" && reload_ssh=1
{
    echo "# Managed by herdr-box bootstrap."
    for t in "${key_types[@]}"; do
        echo "HostKey $STATE_DIR/ssh/ssh_host_${t}_key"
    done
    cat <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys /etc/ssh/authorized_keys/%u
AllowUsers $u
PrintMotd no
PrintLastLog no
AllowAgentForwarding yes
AllowTcpForwarding yes
ClientAliveInterval 30
EOF
} | install_if_changed 644 /etc/ssh/sshd_config.d/60-herdr-box.conf && reload_ssh=1
# sshd -t needs its privilege separation dir, which only the ssh unit creates.
install -d -m 755 /run/sshd
sshd -t || die "sshd config invalid; see above"
if [ "$reload_ssh" = 1 ] && [ -d /run/systemd/system ] && systemctl is-active --quiet ssh.service; then
    systemctl reload-or-restart ssh.service
    changed "sshd: reloaded"
fi

# --- account -------------------------------------------------------------------------
home=/home/$u
# Copies what /etc/skel has and the home lacks; never descends into the home's
# other entries (a mounted ~/projects).
populate_home() {
    local f name
    for f in /etc/skel/.[!.]* /etc/skel/*; do
        [ -e "$f" ] || continue
        name=${f##*/}
        [ -e "$home/$name" ] || [ -L "$home/$name" ] && continue
        cp -a "$f" "$home/$name"
        chown -R "$u:$(id -g "$u")" "$home/$name"
        changed "user $u: added ~/$name from /etc/skel"
    done
}
# A home whose owner is not the account: follow the home (a base image may create
# the account with another uid than its surviving home volume).
home_uid() { stat -c %u "$home"; }
home_gid() { stat -c %g "$home"; }
if id "$u" >/dev/null 2>&1; then
    if [ -d "$home" ] && [ "$(home_uid)" = 0 ]; then
        # runc created the home as root (mount point of a projects bind mount).
        chown "$u:$(id -g "$u")" "$home"
        chmod 750 "$home"
        changed "user $u: took ownership of $home"
        populate_home
    elif [ -d "$home" ] && [ "$(home_uid)" != "$(id -u "$u")" ]; then
        uid=$(home_uid)
        gid=$(home_gid)
        getent passwd "$uid" >/dev/null && die "$home is owned by uid $uid, which another account already uses"
        if [ "$(id -g "$u")" != "$gid" ]; then
            getent group "$gid" >/dev/null && die "$home has gid $gid, which another group already uses"
            groupmod -g "$gid" "$(id -gn "$u")"
        fi
        usermod -u "$uid" "$u"
        changed "user $u: uid $uid to match its home"
    fi
elif [ -d "$home" ] && [ "$(home_uid)" = 0 ]; then
    # Fresh home that runc created for a projects bind mount: a new account.
    useradd -M -d "$home" -s /bin/bash "$u"
    chown "$u:$(id -g "$u")" "$home"
    chmod 750 "$home"
    changed "user $u: created (home created by a mount)"
    populate_home
elif [ -d "$home" ]; then
    # Home survived on its volume (box replaced): reuse its owner IDs.
    uid=$(home_uid)
    gid=$(home_gid)
    getent passwd "$uid" >/dev/null && die "$home is owned by uid $uid, which another account already uses"
    getent group "$gid" >/dev/null || groupadd -g "$gid" "$u"
    useradd -M -d "$home" -s /bin/bash -u "$uid" -g "$gid" "$u"
    changed "user $u: recreated with existing home (uid $uid)"
else
    useradd -m -d "$home" -s /bin/bash "$u"
    changed "user $u: created"
fi
home=$(getent passwd "$u" | cut -d: -f6)

id -nG "$u" | tr ' ' '\n' | grep -qx docker || {
    usermod -aG docker "$u"
    changed "user $u: added to group docker"
}
sudoers=$(mktemp)
echo "$u ALL=(ALL) NOPASSWD:ALL" >"$sudoers"
visudo -cqf "$sudoers" || {
    rm -f "$sudoers"
    die "sudoers drop-in invalid"
}
install_if_changed 440 /etc/sudoers.d/60-herdr-box "$sudoers" || true
rm -f "$sudoers"
if [ ! -e "/var/lib/systemd/linger/$u" ]; then
    # Early in boot logind isn't up yet; it reads the linger file when it starts.
    if systemctl is-active --quiet systemd-logind.service 2>/dev/null; then
        loginctl enable-linger "$u"
    else
        install -d -m 755 /var/lib/systemd/linger
        touch "/var/lib/systemd/linger/$u"
    fi
    changed "user $u: lingering enabled"
fi
shell=$(command -v "$BOX_SHELL") || die "$BOX_SHELL is not installed"
[ "$(getent passwd "$u" | cut -d: -f7)" = "$shell" ] || {
    usermod -s "$shell" "$u"
    changed "user $u: login shell $shell"
}

# zsh with no startup files at all runs its newuser wizard, which waits for input on
# every interactive login (and hangs `ssh -t box zsh -il`). Only when the box has no
# dotfiles: a dotfiles repo owns these files and would conflict with ours.
if [ "$BOX_SHELL" = zsh ] && [ -z "$DOTFILES_REPOSITORY" ] &&
    [ ! -e "$home/.zshenv" ] && [ ! -e "$home/.zprofile" ] && [ ! -e "$home/.zshrc" ] && [ ! -e "$home/.zlogin" ]; then
    echo "# Created by herdr-box: keeps zsh from running its newuser wizard." >"$home/.zshrc"
    chown "$u:" "$home/.zshrc"
    changed "user $u: created ~/.zshrc (no dotfiles)"
fi

# --- environment ---------------------------------------------------------------------
# $box/env plus the box.conf-derived keys, for every shell and wrapper
# (/etc/herdr-box/env) and for systemd user units (environment.d).
env_keys=()
env_values=()
env_add() { # env_add KEY VALUE ORIGIN
    local k
    [[ $1 =~ ^[A-Z_][A-Z0-9_]*$ ]] || die "$3: invalid key '$1'"
    # Both files are read by shells or systemd: keep values free of quoting and expansion.
    [[ $2 == *[\"\'\`\$\\]* ]] && die "$3: value of $1 must not contain quotes, backticks, \$ or backslashes"
    for k in "${env_keys[@]}"; do
        [ "$k" = "$1" ] && die "$3: $1 is set twice"
    done
    env_keys+=("$1")
    env_values+=("$2")
}
if [ -f "$box/env" ]; then
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *=* ]] || die "$box/env:$n: want KEY=value"
        env_add "${line%%=*}" "${line#*=}" "$box/env:$n"
    done <"$box/env"
fi
# omp discovers a llama.cpp server at LLAMA_CPP_BASE_URL (implicit llama.cpp provider).
[ -z "$LLAMA_CPP_URL" ] || env_add LLAMA_CPP_BASE_URL "$LLAMA_CPP_URL" box.conf
if [ -n "$MISE_TRUSTED_PATHS" ]; then
    trusted=
    IFS=: read -ra paths <<<"$MISE_TRUSTED_PATHS"
    for p in "${paths[@]}"; do
        [ -n "$p" ] || continue
        # shellcheck disable=SC2088 # a literal ~ from box.conf
        case $p in "~") p=$home ;; "~/"*) p=$home/${p#"~/"} ;; esac
        trusted=${trusted:+$trusted:}$p
    done
    [ -z "$trusted" ] || env_add MISE_TRUSTED_CONFIG_PATHS "$trusted" box.conf
fi
{
    echo "# Managed by herdr-box bootstrap."
    for i in "${!env_keys[@]}"; do
        printf 'export %s="%s"\n' "${env_keys[i]}" "${env_values[i]}"
    done
} | install_if_changed 644 /etc/herdr-box/env || true
{
    echo "# Managed by herdr-box bootstrap."
    for i in "${!env_keys[@]}"; do
        printf '%s=%s\n' "${env_keys[i]}" "${env_values[i]}"
    done
} | install_if_changed 644 /etc/environment.d/60-herdr-box.conf || true
if [ -e /etc/herdr-box/llm.env ]; then
    rm -f /etc/herdr-box/llm.env
    changed "removed /etc/herdr-box/llm.env (now /etc/herdr-box/env)"
fi

# --- git -----------------------------------------------------------------------------
# Repos under ~/projects may be owned by another uid on the Docker host.
git config --system --get-all safe.directory 2>/dev/null | grep -qxF '*' || {
    git config --system --add safe.directory '*'
    changed "git: safe.directory '*'"
}
