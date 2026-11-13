#!/bin/bash
# End-to-end test of the real image with one box's config (boxes/$BOX), run the way the
# terraform module runs it: boot it with a throwaway SSH key and a throwaway projects
# dir, let both boot units finish, check the second run changes nothing, then smoke +
# checks over real SSH. Finally make the home look older (another uid, no dotfiles
# checkout), replace the container, and check the account follows the home, dotfiles
# come back, and home, host keys, and tools survive. Tailscale login is not exercised
# (the test reaches sshd through a published local port).
# Needs Docker and network access; the first run takes several minutes.
#
# Usage: test/run.sh            KEEP=1 test/run.sh  (leave the container running)
#   BOX  the box config to test: boxes/$BOX (default herdr-box)
set -euo pipefail

cd "$(dirname "$0")/.."
name=herdr-box-test
port=${TEST_SSH_PORT:-2298}
BOX=${BOX:-herdr-box}

pass() { echo "PASS: $*"; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

boxdir=boxes/$BOX
[ -f "$boxdir/box.conf" ] || fail "missing $boxdir/box.conf (copy boxes/example to $boxdir and edit it)"
BOX_USER=
BOX_SHELL=bash
DOTFILES_REPOSITORY=
# shellcheck disable=SC2088 # expanded below, like the bootstrap does
DOTFILES_TARGET_PATH="~/dotfiles"
LLAMA_CPP_URL=
EXTRA_APT_PACKAGES=
# shellcheck source=/dev/null
. "$boxdir/box.conf"
user=$BOX_USER
[ -n "$user" ] || fail "$boxdir/box.conf sets no BOX_USER"
home=/home/$user
dotfiles=${DOTFILES_TARGET_PATH/#\~/$home}

# Lists shared with scripts/smoke.sh: `kind name` lines.
checks() { awk -v k="$1" '$1 == k { printf "%s ", $2 }' config/checks.txt; }

work=$(mktemp -d)
cleanup() {
    if [ "${KEEP:-0}" = 1 ]; then
        echo "container kept: docker exec -it $name bash   (ssh: -p $port -i $work/key $user@127.0.0.1)"
    else
        docker rm -f "$name" >/dev/null 2>&1 || true
        docker volume rm "$name-home" "$name-state" "$name-docker" "$name-containerd" >/dev/null 2>&1 || true
        # The box user leaves files the host user may not own (Linux keeps uids).
        rm -rf "$work" 2>/dev/null ||
            docker run --rm --entrypoint rm -v "$work:/w" herdr-box-test -rf /w/projects >/dev/null 2>&1 || true
        rm -rf "$work" || true
    fi
}
trap cleanup EXIT

# --- fixture: the box dir with a throwaway key and a test env key ----------------------
mkdir -p "$work/box"
cp -R "$boxdir/." "$work/box/"
ssh-keygen -q -t ed25519 -N '' -C test -f "$work/key"
cp "$work/key.pub" "$work/box/authorized_keys"
# Start a new line if the box's env file lacks a trailing newline.
[ -s "$work/box/env" ] && [ -n "$(tail -c1 "$work/box/env")" ] && echo >>"$work/box/env"
echo HERDR_BOX_TEST=ok >>"$work/box/env"
# Always mount a projects dir: Docker then creates the home dir root-owned on the fresh
# home volume, before the account exists, which the first boot must cope with.
# A project made on the host side, like the ones the real mount brings in.
mkdir -p "$work/projects"
git -C "$work/projects" init -q host-repo
git -C "$work/projects/host-repo" -c user.name=test -c user.email=test@example.com \
    commit -q --allow-empty -m init
# Docker Desktop maps the box user to the Mac user; on Linux uids pass through as is.
chmod -R a+rwX "$work/projects"

docker build -q -f image/Dockerfile --build-arg EXTRA_APT_PACKAGES="$EXTRA_APT_PACKAGES" \
    -t herdr-box-test . >/dev/null
docker rm -f "$name" >/dev/null 2>&1 || true
docker volume rm "$name-home" "$name-state" "$name-docker" "$name-containerd" >/dev/null 2>&1 || true

journal() { docker exec "$name" journalctl -u "$1" -o cat --no-pager; }

# Wait for a boot unit's own run: `systemctl start` would retry a failed run and hide
# the failure (a retry can succeed on what the first run left behind), so a restart
# counts as a failure too.
wait_unit() {
    local unit=$1 props='' state='' sub='' restarts=''
    for _ in $(seq 1 1500); do
        props=$(docker exec "$name" systemctl show -p ActiveState -p SubState -p NRestarts "$unit")
        state=$(sed -n 's/^ActiveState=//p' <<<"$props")
        sub=$(sed -n 's/^SubState=//p' <<<"$props")
        restarts=$(sed -n 's/^NRestarts=//p' <<<"$props")
        case $state/$sub in active/* | failed/* | */auto-restart) break ;; esac
        [ "${restarts:-0}" = 0 ] || break
        sleep 1
    done
    [ "$state" = active ] && [ "$restarts" = 0 ] ||
        fail "$unit ($state/$sub, NRestarts=$restarts): $(journal "$unit")"
}

# Same runtime shape as terraform/modules/box, plus a local SSH port and the test box.
boot() {
    docker run -d --name "$name" --hostname "$name" --privileged --cgroupns=private \
        --tmpfs /run --tmpfs /run/lock --shm-size 1g \
        -v "$name-home:/home" -v "$name-state:/var/lib/herdr-box" -v "$name-docker:/var/lib/docker" \
        -v "$name-containerd:/var/lib/containerd" \
        -v "$work/box:/opt/herdr-box/box:ro" -v "$work/projects:$home/projects" \
        -p "127.0.0.1:$port:22" herdr-box-test >/dev/null
    for _ in $(seq 1 30); do
        docker exec "$name" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded|starting' && break
        sleep 1
    done
    wait_unit herdr-box-early.service
    wait_unit herdr-box-bootstrap.service
}
bootstrap() { docker exec "$name" bash /opt/herdr-box/bootstrap/bootstrap.sh; }

# --- boot + bootstrap, then again (idempotency) ---------------------------------------
boot
journal herdr-box-early
journal herdr-box-bootstrap
[ "$(docker exec "$name" stat -c %U "$home")" = "$user" ] || fail "$home is not owned by $user"
pass "boot units (early, bootstrap) without restarts; root-created $home handed to $user"
start=$(date +%s)
bootstrap >"$work/second.log" 2>&1 || fail "bootstrap (second run): $(cat "$work/second.log")"
grep -qx 'herdr-box: changes: 0' "$work/second.log" ||
    fail "second run changed things:
$(grep 'herdr-box: changed: ' "$work/second.log" || cat "$work/second.log")"
pass "second run is a no-op ($(($(date +%s) - start))s)"

# --- checks over real SSH ---------------------------------------------------------------
sshopts=(-p "$port" -i "$work/key" -o BatchMode=yes -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
# shellcheck disable=SC2029 # arguments are remote commands on purpose
sshu() { ssh "${sshopts[@]}" "$user@127.0.0.1" "$@"; }
smoke() {
    HERDR_SSH_OPTS="${sshopts[*]}" scripts/smoke.sh "$user@127.0.0.1"
}

out=$(smoke) || fail "smoke"
echo "$out"
want=$(checks tool)
[ "$(docker exec "$name" dpkg --print-architecture)" = amd64 ] && want="$want$(checks tool-amd64)"
for t in $want; do
    echo "$out" | grep -qw "$t" || fail "hc terminal cannot find $t"
done
pass "smoke + toolchains ($want)"

# Language servers: on every terminal's PATH (smoke), and the native ones actually start.
echo "$out" | grep -q 'language servers missing: none' || fail "hc terminal is missing language servers: $out"
runs=$(checks run)
# shellcheck disable=SC2016 # $t expands in the remote shell
broken=$(sshu "bash -lc 'for t in $runs; do \$t --version >/dev/null 2>&1 || echo \$t; done'") ||
    fail "language server check did not run"
[ -z "$broken" ] || fail "language servers do not run: $broken"
pass "language servers on PATH and runnable ($runs)"

sshu 'hc run --bg --name keep -- sleep 300' >/dev/null
sleep 2
docker exec "$name" loginctl show-user "$user" -p Linger | grep -q 'Linger=yes' || fail "$user not lingering"
sshu 'hc ls' | grep -q keep || fail "terminal gone after logout"
pass "core and terminals survive logout (linger)"

# Nothing trusts repo configs by default: the pin takes effect after an explicit trust.
sshu 'mkdir -p ~/projects/pin && printf "[tools]\nnode = \"24\"\n" > ~/projects/pin/mise.toml && mise trust -q ~/projects/pin'
sshu 'hc run --bg --name pin --cwd ~/projects/pin -- sh -c "node --version; sleep 120"' >/dev/null
for _ in $(seq 1 60); do
    sshu 'hc read pin' | grep -q '^v24\.' && break
    sleep 2
done
sshu 'hc read pin' | grep -q '^v24\.' || fail "repo pin node 24 not used: $(sshu 'hc read pin')"
sshu 'hc kill pin; hc rm pin' >/dev/null 2>&1 || true
pass "trusted repo mise.toml pin (node 24) beats the default"

sshu 'docker run --rm hello-world' | grep -q 'Hello from Docker' || fail "docker run as $user failed"
pass "docker as $user"

# A host-made repo is usable by the box user, and writes show up on the host.
sshu 'git -C ~/projects/host-repo log --oneline' | grep -q init || fail "host repo not usable on the box"
sshu 'echo from-box > ~/projects/host-repo/box.txt'
[ "$(cat "$work/projects/host-repo/box.txt")" = from-box ] || fail "box write not visible on the host"
pass "projects mount: host repo usable by $user, writes reach the host"

sshu 'sudo -n true' || fail "$user has no sudo"
ssh -p "$port" -o BatchMode=yes -o PubkeyAuthentication=no -o PreferredAuthentications=password \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$user@127.0.0.1" true 2>/dev/null &&
    fail "password auth accepted"
pass "sudo; password auth off"

# Login shell, and an interactive login of it (dotfiles included) starts without errors.
[ "$(docker exec "$name" getent passwd "$user" | cut -d: -f7)" = "/usr/bin/$BOX_SHELL" ] || fail "login shell is not $BOX_SHELL"
# `|| true`: the output must reach the check below, not abort under pipefail.
sh_out=$(ssh -tt "${sshopts[@]}" "$user@127.0.0.1" "$BOX_SHELL -il -c true" 2>&1 | tr -d '\r') || true
! grep -iE 'not found|cannot find|error|no such file|permission denied' <<<"$sh_out" ||
    fail "interactive $BOX_SHELL startup printed errors: $sh_out"
pass "login shell $BOX_SHELL starts cleanly"

# Agents run in hc terminals, so the box env (box.conf's model URL and boxes/<box>/env)
# must reach them.
# shellcheck disable=SC2016 # expands in the hc terminal
sshu 'hc run --bg --name envcheck -- sh -c "echo llm-url=\${LLAMA_CPP_BASE_URL:-none} box-test=\${HERDR_BOX_TEST:-none}; sleep 30"' >/dev/null
screen=
for _ in $(seq 1 30); do
    screen=$(sshu 'hc read envcheck') || true
    grep -q 'box-test=' <<<"$screen" && break
    sleep 1
done
sshu 'hc kill envcheck; hc rm envcheck' >/dev/null 2>&1 || true
llm=$(grep -o 'llm-url=[^ ]*' <<<"$screen" | head -n1 | cut -d= -f2-) || true
boxtest=$(grep -o 'box-test=[^ ]*' <<<"$screen" | head -n1 | cut -d= -f2-) || true
[ "$llm" = "${LLAMA_CPP_URL:-none}" ] || fail "hc terminal LLAMA_CPP_BASE_URL is '$llm', want '${LLAMA_CPP_URL:-none}'"
[ "$boxtest" = ok ] || fail "hc terminal HERDR_BOX_TEST is '$boxtest', want 'ok' (from boxes/<box>/env)"
pass "box env in hc terminals (LLAMA_CPP_BASE_URL ${LLAMA_CPP_URL:-unset}, HERDR_BOX_TEST)"

if [ -n "$DOTFILES_REPOSITORY" ]; then
    sshu "test -d '$dotfiles/.git'" || fail "dotfiles checkout missing at $dotfiles"
    # The box owns its checkout: nothing in the home may point into the Mac's projects.
    # (Pruned: a bind mount from the same filesystem shares the device, -xdev or not;
    # mise records the repo configs it has seen or trusted as links in its state dir.)
    # shellcheck disable=SC2016 # expands on the box
    links=$(sshu 'find ~ -xdev \( -path ~/projects -o -path ~/.local/state/mise \) -prune -o -type l -print | while IFS= read -r l; do case $(readlink -f "$l") in "$HOME"/projects | "$HOME"/projects/*) echo "$l" ;; esac; done')
    [ -z "$links" ] || fail "symlinks under home resolve into ~/projects: $links"
    # Claude Code LSP plugins the dotfiles enable need the box's language servers.
    enabled=$(sshu 'jq -r ".enabledPlugins // {} | to_entries[] | select(.value) | .key" ~/.claude/settings.json 2>/dev/null' || true)
    installed=$(sshu 'bash -lc "claude plugin list --json"' | jq -r '.[].id')
    for p in rust-analyzer-lsp lua-lsp pyright-lsp typescript-lsp; do
        grep -qxF "$p@claude-plugins-official" <<<"$enabled" || continue
        grep -qxF "$p@claude-plugins-official" <<<"$installed" || fail "enabled claude plugin $p not installed: $installed"
    done
    pass "dotfiles: checkout at $dotfiles, no links into ~/projects; enabled claude LSP plugins installed"
fi

# --- replace the container with an older home: account, dotfiles, host keys, tools ------
# Make the home look older: owned by another uid, and without the dotfiles checkout. The
# next boot must give the account the home's uid and clone the dotfiles again.
# Only the home volume: a mounted ~/projects comes from the host as is.
docker exec "$name" sh -c "cd $home && find . -xdev -path ./projects -prune -o -exec chown -h 1005:1005 {} +"
[ -z "$DOTFILES_REPOSITORY" ] || docker exec "$name" rm -rf "$dotfiles"
hostkey=$(ssh-keyscan -p "$port" -t ed25519 127.0.0.1 2>/dev/null | cut -d' ' -f3)
docker rm -f "$name" >/dev/null
start=$(date +%s)
boot
[ "$(docker exec "$name" id -u "$user")" = 1005 ] || fail "account uid does not follow its home's owner (1005)"
if [ -n "$DOTFILES_REPOSITORY" ]; then
    grep -q "dotfiles: cloning" <<<"$(journal herdr-box-bootstrap)" || fail "dotfiles not cloned again"
    sshu "test -d '$dotfiles/.git'" || fail "dotfiles checkout missing after replace"
fi
[ "$(ssh-keyscan -p "$port" -t ed25519 127.0.0.1 2>/dev/null | cut -d' ' -f3)" = "$hostkey" ] || fail "host key changed"
# Tailscale SSH (not exercised here) presents /etc/ssh's keys: they must be sshd's.
docker exec "$name" cmp -s /etc/ssh/ssh_host_ed25519_key /var/lib/herdr-box/ssh/ssh_host_ed25519_key ||
    fail "/etc/ssh host key differs from the state volume's (Tailscale SSH would present another identity)"
smoke >/dev/null || fail "smoke after replace"
pass "replaced container keeps home, host key, tools; uid follows home (boot $(($(date +%s) - start))s)"

echo "ALL PASS"
