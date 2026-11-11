#!/bin/bash
# herdr-box host bootstrap (Ubuntu 24.04, run as root). Idempotent: the container
# runs it on every boot (herdr-box-bootstrap.service); scripts/deploy.sh re-runs it
# on a live box (the container now, a dedicated machine later).
#
# Usage: bootstrap.sh [--config DIR] [--system]
#   --config DIR  directory with box.conf, authorized_keys, mise.toml, mise.amd64.toml
#                 (default: ../config next to this script)
#   --system      only the system layer (apt, Docker, Tailscale, mise, wrappers), with
#                 no running systemd or account; image/Dockerfile bakes it in at build
#
# What it manages:
#   - apt packages, Docker (rootful; the box has one user), Tailscale
#   - mise + toolchain defaults (/etc/mise/conf.d), installed for BOX_USER
#   - sshd (keys only, AllowUsers BOX_USER, quiet non-interactive logins), with
#     host keys kept in /var/lib/herdr-box so clients keep trusting a replaced box
#   - the BOX_USER account: login shell BOX_SHELL, passwordless sudo, docker group, lingering
#   - herdr-core, herdr TUI, Claude Code, Codex, omp in ~/.local/bin (+ herdr integrations)
#   - dotfiles via bootstrap/dotfiles.sh (run as BOX_USER), when box.conf sets DOTFILES_REPO
set -euo pipefail

say() { echo "herdr-box: $*"; }
die() {
    echo "herdr-box: $*" >&2
    exit 1
}

root=$(cd "$(dirname "$0")/.." && pwd)
config=$root/config
system_only=0
while [ $# -gt 0 ]; do
    case $1 in
        --config)
            [ $# -ge 2 ] || die "--config needs a directory"
            config=$2
            shift 2
            ;;
        --system)
            system_only=1
            shift
            ;;
        -h | --help)
            sed -n '2,19p' "$0"
            exit 0
            ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || die "run as root"
command -v apt-get >/dev/null || die "apt-get not found; this bootstrap targets Ubuntu 24.04"
for f in mise.toml mise.amd64.toml; do
    [ -f "$config/$f" ] || die "missing $config/$f"
done
if [ "$system_only" = 0 ]; then
    for f in box.conf authorized_keys; do
        [ -f "$config/$f" ] || die "missing $config/$f (copy $config/$f.example and edit it)"
    done
    BOX_USER=
    BOX_SHELL=bash
    DOTFILES_REPO=
    DOTFILES_SETUP=linux/setup.sh
    # shellcheck source=/dev/null
    . "$config/box.conf"
    u=$BOX_USER
    [[ $u =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid BOX_USER '$u' in box.conf"
    grep -Eq '^(ssh-|ecdsa-|sk-)' "$config/authorized_keys" || die "$config/authorized_keys has no SSH public key"
    case $BOX_SHELL in bash | zsh) ;; *) die "BOX_SHELL must be bash or zsh, not '$BOX_SHELL'" ;; esac
fi

STATE_DIR=/var/lib/herdr-box
arch=$(dpkg --print-architecture)
# shellcheck source=/dev/null
codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
export DEBIAN_FRONTEND=noninteractive

# --- apt -------------------------------------------------------------------------
repo() { # repo <name> <key-url> <key-ext asc|gpg> <deb source>
    local list=/etc/apt/sources.list.d/$1.list key=/etc/apt/keyrings/$1.$3
    [ -f "$list" ] && return 0
    install -d -m 755 /etc/apt/keyrings
    curl -fsSL "$2" -o "$key"
    chmod 644 "$key"
    echo "deb [arch=$arch signed-by=$key] $4" >"$list"
    say "apt: added repo $1"
}
repo docker https://download.docker.com/linux/ubuntu/gpg asc \
    "https://download.docker.com/linux/ubuntu $codename stable"
repo tailscale "https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg" gpg \
    "https://pkgs.tailscale.com/stable/ubuntu $codename main"

pkgs=(openssh-server sudo git curl ca-certificates jq ripgrep less procps unzip zip
    xz-utils build-essential python3 libatomic1
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    tailscale zsh
    libicu74) # marksman (markdown language server) is a .NET binary that needs ICU
# Flutter's Linux deps; Flutter itself is amd64-only (see mise section).
[ "$arch" = amd64 ] && pkgs+=(libglu1-mesa)
missing=()
for p in "${pkgs[@]}"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
    say "apt: installing ${missing[*]}"
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing[@]}" >/dev/null
fi
systemctl enable docker.service tailscaled.service >/dev/null 2>&1
# Only when systemd runs: an image build (--system) has none.
if [ -d /run/systemd/system ]; then
    systemctl start docker.service tailscaled.service
fi

# --- mise toolchain defaults --------------------------------------------------------
if ! command -v mise >/dev/null; then
    say "installing mise"
    curl -fsSL https://mise.run | MISE_INSTALL_PATH=/usr/local/bin/mise sh >/dev/null
fi
install -d -m 755 /etc/mise/conf.d
install -m 644 "$config/mise.toml" /etc/mise/conf.d/herdr-box.toml
# Flutter publishes no linux-arm64 SDK, and Android build tools are x86_64-only.
if [ "$arch" = amd64 ]; then
    install -m 644 "$config/mise.amd64.toml" /etc/mise/conf.d/herdr-box-amd64.toml
else
    rm -f /etc/mise/conf.d/herdr-box-amd64.toml
    say "mise: skipping mise.amd64.toml (flutter) on $arch"
fi

# --- environment: login shells, and every herdr entry point -----------------------
cat >/etc/profile.d/herdr-box.sh <<'EOF'
# Managed by herdr-box bootstrap.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
case ":$PATH:" in *":$HOME/.local/share/mise/shims:"*) ;; *) PATH="$HOME/.local/share/mise/shims:$PATH" ;; esac
export PATH
export MISE_TRUSTED_CONFIG_PATHS="$HOME/projects"
EOF
# zsh login shells skip /etc/profile.d; source the same definition from zprofile.
zprofile_line=". /etc/profile.d/herdr-box.sh # managed by herdr-box bootstrap"
grep -qxF "$zprofile_line" /etc/zsh/zprofile 2>/dev/null || echo "$zprofile_line" >>/etc/zsh/zprofile
# Non-interactive SSH (how Herdr clients connect) uses sshd's default PATH. These
# wrappers run the user's own ~/.local/bin install (which self-updates) with the
# environment above: the core inherits the environment of the hc process that
# starts it, and every terminal and agent inherits the core's.
for tool in herdr-core hc herdr; do
    bin=$tool
    [ "$tool" = hc ] && bin=herdr-core
    cat >"/usr/local/bin/$tool" <<EOF
#!/bin/sh
# Managed by herdr-box bootstrap: run this user's own $bin.
. /etc/profile.d/herdr-box.sh
target="\$HOME/.local/bin/$bin"
[ -x "\$target" ] || { echo "herdr-box: $bin is not installed for \$(id -un); re-run the bootstrap" >&2; exit 127; }
exec "\$target" "\$@"
EOF
    chmod 755 "/usr/local/bin/$tool"
done
install -m 755 "$root/bootstrap/bin/herdr-box-update" /usr/local/bin/herdr-box-update

if [ "$system_only" = 1 ]; then
    say "system layer done"
    exit 0
fi

# --- sshd --------------------------------------------------------------------------
# Host keys live in STATE_DIR (a volume in the container), so a replaced box keeps
# its identity.
install -d -m 700 "$STATE_DIR/ssh"
if compgen -G "$STATE_DIR/ssh/ssh_host_*" >/dev/null; then
    cmp -s "$STATE_DIR/ssh/ssh_host_ed25519_key" /etc/ssh/ssh_host_ed25519_key || {
        cp -p "$STATE_DIR"/ssh/ssh_host_* /etc/ssh/
        say "sshd: restored host keys from $STATE_DIR/ssh"
    }
else
    cp -p /etc/ssh/ssh_host_* "$STATE_DIR/ssh/"
    say "sshd: saved host keys to $STATE_DIR/ssh"
fi
install -d -m 755 /etc/ssh/authorized_keys
install -m 644 "$config/authorized_keys" "/etc/ssh/authorized_keys/$u"
cat >/etc/ssh/sshd_config.d/60-herdr-box.conf <<EOF
# Managed by herdr-box bootstrap.
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
sshd -t || die "sshd config invalid; see above"
systemctl try-reload-or-restart ssh.service 2>/dev/null || true

# --- account -------------------------------------------------------------------------
if id "$u" >/dev/null 2>&1; then
    # A base image may create the account with another uid than its surviving home
    # (e.g. the dotfiles image's 1000 vs an older volume's 1001): follow the home.
    if [ -d "/home/$u" ] && [ "$(stat -c %u "/home/$u")" != "$(id -u "$u")" ]; then
        uid=$(stat -c %u "/home/$u")
        gid=$(stat -c %g "/home/$u")
        getent passwd "$uid" >/dev/null && die "/home/$u is owned by uid $uid, which another account already uses"
        if [ "$(id -g "$u")" != "$gid" ]; then
            getent group "$gid" >/dev/null && die "/home/$u has gid $gid, which another group already uses"
            groupmod -g "$gid" "$(id -gn "$u")"
        fi
        usermod -u "$uid" "$u"
        say "user $u: uid $uid to match its home"
    fi
else
    if [ -d "/home/$u" ]; then
        # Home survived on its volume (box replaced): reuse its owner IDs.
        uid=$(stat -c %u "/home/$u")
        gid=$(stat -c %g "/home/$u")
        getent passwd "$uid" >/dev/null && die "/home/$u is owned by uid $uid, which another account already uses"
        getent group "$gid" >/dev/null || groupadd -g "$gid" "$u"
        useradd -M -d "/home/$u" -s /bin/bash -u "$uid" -g "$gid" "$u"
        say "user $u: recreated with existing home (uid $uid)"
    else
        useradd -m -s /bin/bash "$u"
        say "user $u: created"
    fi
fi
usermod -aG docker "$u"
echo "$u ALL=(ALL) NOPASSWD:ALL" >/etc/sudoers.d/60-herdr-box
chmod 440 /etc/sudoers.d/60-herdr-box
visudo -cqf /etc/sudoers.d/60-herdr-box || die "sudoers drop-in invalid"
loginctl enable-linger "$u"
shell=$(command -v "$BOX_SHELL")
[ "$(getent passwd "$u" | cut -d: -f7)" = "$shell" ] || {
    usermod -s "$shell" "$u"
    say "user $u: login shell $shell"
}

# --- user tools ------------------------------------------------------------------------
home=$(getent passwd "$u" | cut -d: -f6)
say "user $u: tools"
as_user() {
    (cd "$home" && runuser -u "$u" -- env -i HOME="$home" USER="$u" LOGNAME="$u" SHELL=/bin/bash \
        LANG=C.UTF-8 PATH="$home/.local/bin:$home/.local/share/mise/shims:/usr/local/bin:/usr/bin:/bin" \
        MISE_YES=1 "$@")
}
as_user bash -euo pipefail -c '
        mkdir -p ~/.local/bin ~/projects ~/.omp/agent/extensions
        [ -x ~/.local/bin/herdr-core ] || curl -fsSL https://releases.herdr.dev/core/install.sh | sh
        [ -x ~/.local/bin/herdr ] || curl -fsSL https://herdr.dev/install.sh | sh
        [ -x ~/.local/bin/claude ] || curl -fsSL https://claude.ai/install.sh | bash
        [ -x ~/.local/bin/codex ] || curl -fsSL https://chatgpt.com/codex/install.sh | sh
        [ -x ~/.local/bin/omp ] || curl -fsSL https://omp.sh/install | sh -s -- --binary
        # The installer skips its hc link when an hc (our wrapper) is already on PATH.
        [ -e ~/.local/bin/hc ] || ln -s herdr-core ~/.local/bin/hc
        mise install
    ' >/dev/null

# --- dotfiles (optional) -----------------------------------------------------------------
# After the tools (its install may set up herdr/omp plugins), before the integrations
# (it may link their files into place).
if [ -n "$DOTFILES_REPO" ]; then
    say "user $u: dotfiles"
    as_user bash "$root/bootstrap/dotfiles.sh" "$DOTFILES_REPO" "$DOTFILES_SETUP" >/dev/null
fi

# --- herdr agent integrations ----------------------------------------------------------
# Only when missing: a re-install rewrites the agent configs, which may be links into
# the dotfiles repo.
as_user bash -euo pipefail -c '
        [ -e ~/.claude/hooks/herdr-agent-state.sh ] || herdr integration install claude
        [ -e ~/.codex/herdr-agent-state.sh ] || herdr integration install codex
        [ -e ~/.omp/agent/extensions/herdr-omp-agent-state.ts ] || herdr integration install omp
    ' >/dev/null

# --- tailscale -------------------------------------------------------------------------
if tailscale status >/dev/null 2>&1; then
    say "tailscale: up as $(tailscale status --json | jq -r .Self.DNSName)"
else
    say "tailscale: not logged in; run 'sudo tailscale up --hostname=$(hostname)' on the box (container: mise run ts:up)"
fi

say "done: user $u, arch $arch"
