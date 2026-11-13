# shellcheck shell=bash disable=SC2154
# Phase packages: apt repos (pinned key fingerprints), apt packages, the mise binary.
# Sourced by bootstrap.sh (globals from lib/common.sh). Runs at image build too, so it
# needs no box config and no running systemd.

# renovate: datasource=github-releases depName=jdx/mise
MISE_VERSION=2026.11.6

apt_updated=0
apt_install() { # apt_install PKG...: install the given packages, refreshing lists once per run
    if [ "$apt_updated" = 0 ]; then
        apt-get update -qq
        apt_updated=1
    fi
    apt-get install -y -qq --no-install-recommends "$@" >/dev/null
    changed "apt: installed $*"
}
apt_missing() { # apt_missing PKG...: print the ones not installed
    local p
    for p; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || echo "$p"
    done
}

# Fetching and verifying repo keys needs these before anything else.
mapfile -t missing < <(apt_missing curl ca-certificates gnupg)
if [ ${#missing[@]} -gt 0 ]; then apt_install "${missing[@]}"; fi

# key_fingerprint FILE: the primary key fingerprint(s) in FILE, one per line.
key_fingerprint() {
    local gnupg rc=0
    gnupg=$(mktemp -d)
    GNUPGHOME=$gnupg gpg --batch --show-keys --with-colons "$1" 2>/dev/null |
        awk -F: '$1 == "pub" { p = 1; next } $1 == "fpr" && p { print $10; p = 0 } $1 == "sub" { p = 0 }' || rc=$?
    rm -rf "$gnupg"
    return "$rc"
}
# repo NAME KEY_URL KEY_EXT FINGERPRINT SOURCE. apt trusts every key in a signed-by
# file, so the file must hold exactly the pinned key.
repo() {
    local name=$1 url=$2 ext=$3 fpr=$4 src=$5 key list tmp
    key=/etc/apt/keyrings/$name.$ext
    list=/etc/apt/sources.list.d/$name.list
    if [ ! -f "$key" ] || [ "$(key_fingerprint "$key")" != "$fpr" ]; then
        tmp=$(mktemp)
        curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 "$url" -o "$tmp" ||
            die "apt: cannot download the $name key from $url"
        [ "$(key_fingerprint "$tmp")" = "$fpr" ] ||
            die "apt: the $name key from $url is not the pinned key $fpr"
        install_if_changed 644 "$key" "$tmp" || true
        rm -f "$tmp"
    fi
    echo "deb [arch=$arch signed-by=$key] $src" | install_if_changed 644 "$list" || true
}
repo docker https://download.docker.com/linux/ubuntu/gpg asc \
    9DC858229FC7DD38854AE2D88D81803C0EBFCD88 \
    "https://download.docker.com/linux/ubuntu $codename stable"
repo tailscale "https://pkgs.tailscale.com/stable/ubuntu/$codename.noarmor.gpg" gpg \
    2596A99EAAB33821893C0A79458CA832957F5868 \
    "https://pkgs.tailscale.com/stable/ubuntu $codename main"

pkgs=(openssh-server sudo git curl ca-certificates gnupg jq ripgrep less procps unzip zip
    xz-utils build-essential python3 libatomic1
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    tailscale zsh
    libicu74) # marksman (markdown language server) is a .NET binary that needs ICU
# Flutter's Linux deps; Flutter itself is amd64-only (see 20-system).
[ "$arch" = amd64 ] && pkgs+=(libglu1-mesa)
# Per-box extras (validated by the driver or load_box_config).
read -ra extra <<<"$EXTRA_APT_PACKAGES"
pkgs+=("${extra[@]}")
mapfile -t missing < <(apt_missing "${pkgs[@]}")
if [ ${#missing[@]} -gt 0 ]; then apt_install "${missing[@]}"; fi

for unit in docker.service tailscaled.service; do
    if ! systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        systemctl enable --quiet "$unit"
        changed "systemd: enabled $unit"
    fi
done
# Only when systemd runs: an image build has none.
if [ -d /run/systemd/system ]; then
    for unit in docker.service tailscaled.service; do
        if ! systemctl is-active --quiet "$unit"; then
            systemctl start "$unit"
            changed "systemd: started $unit"
        fi
    done
fi

# --- mise binary, pinned (toolchain defaults are 20-system's) ---------------------------
mise_version() { /usr/local/bin/mise --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -n 1; }
if [ "$(mise_version || true)" != "$MISE_VERSION" ]; then
    tmp=$(mktemp)
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 https://mise.run -o "$tmp" ||
        die "mise: cannot download the installer from https://mise.run"
    MISE_VERSION=v$MISE_VERSION MISE_INSTALL_PATH=/usr/local/bin/mise sh "$tmp" >/dev/null
    rm -f "$tmp"
    [ "$(mise_version || true)" = "$MISE_VERSION" ] || die "mise: installed, but it is not $MISE_VERSION"
    changed "mise: installed $MISE_VERSION"
fi
