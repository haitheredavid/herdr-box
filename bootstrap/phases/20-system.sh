# shellcheck shell=bash disable=SC2154
# Phase system: mise toolchain defaults, the login environment, herdr wrappers and
# herdr-box-update. Sourced by bootstrap.sh (globals from lib/common.sh); runs at image
# build too, from the shared config only.

for f in mise.toml mise.amd64.toml; do
    [ -f "$config/$f" ] || die "missing $config/$f"
done

# --- mise toolchain defaults --------------------------------------------------------
install_if_changed 644 /etc/mise/conf.d/herdr-box.toml "$config/mise.toml" || true
# Flutter publishes no linux-arm64 SDK, and Android build tools are x86_64-only.
if [ "$arch" = amd64 ]; then
    install_if_changed 644 /etc/mise/conf.d/herdr-box-amd64.toml "$config/mise.amd64.toml" || true
else
    if [ -e /etc/mise/conf.d/herdr-box-amd64.toml ]; then
        rm -f /etc/mise/conf.d/herdr-box-amd64.toml
        changed "removed /etc/mise/conf.d/herdr-box-amd64.toml"
    fi
    say "mise: skipping mise.amd64.toml (flutter) on $arch"
fi

# --- environment: login shells, and every herdr entry point -----------------------
# The box env (/etc/herdr-box/env, from 30-host) carries per-box variables such as
# LLAMA_CPP_BASE_URL and MISE_TRUSTED_CONFIG_PATHS.
install_if_changed 644 /etc/profile.d/herdr-box.sh <<'EOF' || true
# Managed by herdr-box bootstrap.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
case ":$PATH:" in *":$HOME/.local/share/mise/shims:"*) ;; *) PATH="$HOME/.local/share/mise/shims:$PATH" ;; esac
export PATH
if [ -r /etc/herdr-box/env ]; then . /etc/herdr-box/env; fi
EOF
# zsh login shells skip /etc/profile.d; source the same definition from zprofile.
zprofile_line=". /etc/profile.d/herdr-box.sh # managed by herdr-box bootstrap"
if ! grep -qxF "$zprofile_line" /etc/zsh/zprofile 2>/dev/null; then
    {
        # Keep the existing file, ending it with a newline before the hook.
        # shellcheck disable=SC1003 # sed's "append newline if missing" idiom
        if [ -f /etc/zsh/zprofile ]; then sed -e '$a\' /etc/zsh/zprofile; fi
        echo "$zprofile_line"
    } | install_if_changed 644 /etc/zsh/zprofile || true
fi
# Non-interactive SSH (how Herdr clients connect) uses sshd's default PATH. These
# wrappers run the user's own ~/.local/bin install (which self-updates) with the
# environment above: the core inherits the environment of the hc process that
# starts it, and every terminal and agent inherits the core's.
for tool in herdr-core hc herdr; do
    bin=$tool
    [ "$tool" = hc ] && bin=herdr-core
    install_if_changed 755 "/usr/local/bin/$tool" <<EOF || true
#!/bin/sh
# Managed by herdr-box bootstrap: run this user's own $bin.
. /etc/profile.d/herdr-box.sh
target="\$HOME/.local/bin/$bin"
[ -x "\$target" ] || { echo "herdr-box: $bin is not installed for \$(id -un); re-run the bootstrap" >&2; exit 127; }
exec "\$target" "\$@"
EOF
done
install_if_changed 755 /usr/local/bin/herdr-box-update "$root/bootstrap/bin/herdr-box-update" || true
