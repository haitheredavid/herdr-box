# shellcheck shell=bash disable=SC2154 # root, box: set by bootstrap.sh
# Phase user: sourced by bootstrap.sh after lib/common.sh and load_box_config.
# Runs late (herdr-box-bootstrap.service), networked: agent tools, hc link, dotfiles,
# mise install, herdr integrations, tailscale report. A failing step is recorded
# and the rest still run; the phase fails at the end so the unit retries.

u=$BOX_USER
home=$(getent passwd "$u" | cut -d: -f6)
[ -n "$home" ] || die "user $u does not exist; run the host phase first"
failed=()

as_user mkdir -p "$home/.local/bin" "$home/projects" "$home/.omp/agent/extensions"

# --- agent tools ---------------------------------------------------------------------
# Read the table up front: as_user must not consume the loop's stdin.
tool_names=()
tool_installers=()
tool_runners=()
tool_args=()
tool_sentinels=()
while IFS=$'\t' read -r name installer runner args _update sentinel || [ -n "$name" ]; do
    [[ -z $name || $name == \#* ]] && continue
    [[ $name =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "$root/config/tools.tsv: invalid name '$name'"
    case $runner in sh | bash) ;; *) die "$root/config/tools.tsv: $name: runner must be sh or bash" ;; esac
    tool_names+=("$name")
    tool_installers+=("$installer")
    tool_runners+=("$runner")
    tool_args+=("$args")
    tool_sentinels+=("$sentinel")
done <"$root/config/tools.tsv"

for i in "${!tool_names[@]}"; do
    name=${tool_names[i]}
    as_user "$home/.local/bin/$name" --version </dev/null >/dev/null 2>&1 && continue
    args=()
    # Word splitting is the format: args are space separated.
    # shellcheck disable=SC2206
    [ "${tool_args[i]}" = - ] || args=(${tool_args[i]})
    # shellcheck disable=SC2016
    if as_user bash -euo pipefail -c '
            f=$(mktemp)
            trap '\''rm -f "$f"'\'' EXIT
            curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -o "$f" "$1"
            runner=$2
            shift 2
            "$runner" "$f" "$@"
        ' _ "${tool_installers[i]}" "${tool_runners[i]}" "${args[@]}" </dev/null >/dev/null; then
        changed "installed $name"
    else
        say "user $u: installing $name failed" >&2
        failed+=("$name")
    fi
done
# The installer skips its hc link when an hc (our wrapper) is already on PATH.
if [ ! -e "$home/.local/bin/hc" ] && [ ! -L "$home/.local/bin/hc" ]; then
    as_user ln -s herdr-core "$home/.local/bin/hc"
    changed "user $u: linked ~/.local/bin/hc"
fi

# --- dotfiles (optional) -------------------------------------------------------------
# After the tools (its install may set up herdr/omp plugins), before mise (it may
# add tool config) and the integrations (it may link their files into place).
if [ -n "$DOTFILES_REPOSITORY" ]; then
    as_user bash "$root/bootstrap/dotfiles.sh" "$DOTFILES_REPOSITORY" "$DOTFILES_REF" \
        "$DOTFILES_TARGET_PATH" "$DOTFILES_INSTALL_COMMAND" </dev/null || {
        say "user $u: dotfiles failed" >&2
        failed+=(dotfiles)
    }
fi

# --- mise toolchains -----------------------------------------------------------------
if missing=$(as_user mise ls --missing --json </dev/null |
    jq -r 'to_entries[] | select(.value | length > 0) | .key'); then
    if [ -n "$missing" ]; then
        changed "mise install: $(echo "$missing" | tr '\n' ' ')"
        as_user mise install </dev/null >/dev/null || {
            say "user $u: mise install failed" >&2
            failed+=(mise)
        }
    fi
else
    say "user $u: mise ls --missing failed" >&2
    failed+=(mise)
fi

# --- herdr agent integrations --------------------------------------------------------
# Only when missing: a re-install rewrites the agent configs, which may be links into
# the dotfiles repo.
for i in "${!tool_names[@]}"; do
    name=${tool_names[i]}
    sentinel=${tool_sentinels[i]}
    [ "$sentinel" = - ] || [ -z "$sentinel" ] || [ -e "$home/$sentinel" ] && continue
    if as_user herdr integration install "$name" </dev/null >/dev/null; then
        changed "herdr integration $name"
    else
        say "user $u: herdr integration $name failed" >&2
        failed+=("integration:$name")
    fi
done

# --- tailscale -----------------------------------------------------------------------
if tailscale status >/dev/null 2>&1; then
    say "tailscale: up as $(tailscale status --json | jq -r .Self.DNSName)"
else
    say "tailscale: not logged in; run 'sudo tailscale up --hostname=$(hostname) --ssh' on the box (container: mise run ts:up)"
fi

[ ${#failed[@]} -eq 0 ] || die "user phase failed: ${failed[*]}"
