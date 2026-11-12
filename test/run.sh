#!/bin/bash
# End-to-end test of the real image with your config/box.conf, built like terraform
# builds it (on the dotfiles_dir base image from terraform/terraform.tfvars, if any):
# boot it with a throwaway SSH key, let the boot bootstrap finish, check idempotency,
# then smoke + checks over real SSH. Finally make the home look older (another uid,
# no dotfiles repo), replace the container, and check the account follows the home,
# dotfiles come back, and home, host keys, and tools survive. Tailscale login is not
# exercised (the test reaches sshd through a published local port).
# Needs Docker and network access; the first run takes several minutes.
#
# Usage: test/run.sh            KEEP=1 test/run.sh  (leave the container running)
#   DOTFILES_DIR  override terraform's dotfiles_dir ("" for a plain Ubuntu base)
#   PROJECTS_DIR  override terraform's projects_dir; when set, a throwaway projects dir
#                 (never the real one) is mounted at ~/projects the same way
set -euo pipefail

cd "$(dirname "$0")/.."
name=herdr-box-test
port=${TEST_SSH_PORT:-2298}

pass() { echo "PASS: $*"; }
fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f config/box.conf ] || fail "missing config/box.conf (copy config/box.conf.example and edit it)"
BOX_USER=
BOX_SHELL=bash
DOTFILES_REPO=
LLAMA_CPP_URL=
# shellcheck source=/dev/null
. config/box.conf
user=$BOX_USER
if [ -z "${DOTFILES_DIR+set}" ]; then
    DOTFILES_DIR=$(sed -n 's/^ *dotfiles_dir *= *"\(.*\)".*/\1/p' terraform/terraform.tfvars 2>/dev/null || true)
fi
DOTFILES_DIR=${DOTFILES_DIR/#\~/$HOME}
if [ -z "${PROJECTS_DIR+set}" ]; then
    PROJECTS_DIR=$(sed -n 's/^ *projects_dir *= *"\(.*\)".*/\1/p' terraform/terraform.tfvars 2>/dev/null || true)
fi

work=$(mktemp -d)
cleanup() {
    if [ "${KEEP:-0}" = 1 ]; then
        echo "container kept: docker exec -it $name bash   (ssh: -p $port -i $work/key $user@127.0.0.1)"
    else
        docker rm -f "$name" >/dev/null 2>&1 || true
        docker volume rm "$name-home" "$name-state" "$name-docker" "$name-containerd" >/dev/null 2>&1 || true
        rm -rf "$work"
    fi
}
trap cleanup EXIT

# --- fixture: the repo config with a throwaway key -------------------------------------
cp -R config "$work/config"
ssh-keygen -q -t ed25519 -N '' -C test -f "$work/key"
cp "$work/key.pub" "$work/config/authorized_keys"
projects=()
if [ -n "$PROJECTS_DIR" ]; then
    # A project made on the host side, like the ones the real mount brings in.
    mkdir -p "$work/projects"
    git -C "$work/projects" init -q host-repo
    git -C "$work/projects/host-repo" -c user.name=test -c user.email=test@example.com \
        commit -q --allow-empty -m init
    projects=(-v "$work/projects:/home/$user/projects")
fi

base=ubuntu:24.04
if [ -n "$DOTFILES_DIR" ]; then
    docker build -q -f "$DOTFILES_DIR/linux/Dockerfile" -t herdr-box-test-dotfiles "$DOTFILES_DIR" >/dev/null
    base=herdr-box-test-dotfiles
fi
docker build -q -f image/Dockerfile --build-arg BASE="$base" -t herdr-box-test . >/dev/null
docker rm -f "$name" >/dev/null 2>&1 || true
docker volume rm "$name-home" "$name-state" "$name-docker" "$name-containerd" >/dev/null 2>&1 || true

# Same runtime shape as terraform/main.tf, plus a local SSH port and the test config.
boot() {
    docker run -d --name "$name" --hostname "$name" --privileged --cgroupns=private \
        --tmpfs /run --tmpfs /run/lock \
        -v "$name-home:/home" -v "$name-state:/var/lib/herdr-box" -v "$name-docker:/var/lib/docker" \
        -v "$name-containerd:/var/lib/containerd" \
        -v "$work/config:/opt/herdr-box/config:ro" ${projects[@]+"${projects[@]}"} \
        -p "127.0.0.1:$port:22" herdr-box-test >/dev/null
    for _ in $(seq 1 30); do
        docker exec "$name" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded|starting' && break
        sleep 1
    done
    # Wait for the boot-time run itself: `systemctl start` would retry a failed run
    # and hide the failure (a retry can succeed on what the first run left behind).
    local state=
    for _ in $(seq 1 900); do
        state=$(docker exec "$name" systemctl show -p ActiveState --value herdr-box-bootstrap.service)
        case $state in active | failed) break ;; esac
        sleep 1
    done
    [ "$state" = active ] ||
        fail "boot bootstrap ($state): $(docker exec "$name" journalctl -u herdr-box-bootstrap -o cat --no-pager)"
}
bootstrap() { docker exec "$name" bash /opt/herdr-box/bootstrap/bootstrap.sh; }

# --- boot + bootstrap, then again (idempotency) ---------------------------------------
boot
docker exec "$name" journalctl -u herdr-box-bootstrap -o cat --no-pager
pass "boot bootstrap (base $base)"
start=$(date +%s)
bootstrap >"$work/second.log" 2>&1 || fail "bootstrap (second run): $(cat "$work/second.log")"
grep -qE 'apt: installing|installing mise|created|added repo|saved host keys|login shell|dotfiles: (cloning|seeding)' "$work/second.log" &&
    fail "second run redid work: $(cat "$work/second.log")"
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
want="claude codex omp mise node pnpm tsc python uv cargo rustc just databricks docker"
[ "$(docker exec "$name" dpkg --print-architecture)" = amd64 ] && want="$want flutter"
for t in $want; do
    echo "$out" | grep -qw "$t" || fail "hc terminal cannot find $t"
done
pass "smoke + toolchains ($want)"

# Language servers: on every terminal's PATH (smoke), and the native ones actually start
# (marksman, a .NET binary, needs libicu).
echo "$out" | grep -q 'language servers missing: none' || fail "hc terminal is missing language servers: $out"
# shellcheck disable=SC2016 # $t expands in the remote shell
sshu 'bash -lc "for t in rust-analyzer ty ruff lua-language-server marksman taplo terraform-ls shellcheck; do \$t --version >/dev/null 2>&1 || { echo \$t; exit 1; }; done"' ||
    fail "a language server does not run"
pass "language servers on PATH and runnable"

sshu 'hc run --bg --name keep -- sleep 300' >/dev/null
sleep 2
docker exec "$name" loginctl show-user "$user" -p Linger | grep -q 'Linger=yes' || fail "$user not lingering"
sshu 'hc ls' | grep -q keep || fail "terminal gone after logout"
pass "core and terminals survive logout (linger)"

sshu 'mkdir -p ~/projects/pin && printf "[tools]\nnode = \"24\"\n" > ~/projects/pin/mise.toml'
sshu 'hc run --bg --name pin --cwd ~/projects/pin -- sh -c "node --version; sleep 120"' >/dev/null
for _ in $(seq 1 60); do
    sshu 'hc read pin' | grep -q '^v24\.' && break
    sleep 2
done
sshu 'hc read pin' | grep -q '^v24\.' || fail "repo pin node 24 not used: $(sshu 'hc read pin')"
pass "repo mise.toml pin (node 24) beats the default"

sshu 'docker run --rm hello-world' | grep -q 'Hello from Docker' || fail "docker run as $user failed"
pass "docker as $user"

if [ -n "$PROJECTS_DIR" ]; then
    # A host-made repo is usable by the box user, and writes show up on the host.
    sshu 'git -C ~/projects/host-repo log --oneline' | grep -q init || fail "host repo not usable on the box"
    sshu 'echo from-box > ~/projects/host-repo/box.txt'
    [ "$(cat "$work/projects/host-repo/box.txt")" = from-box ] || fail "box write not visible on the host"
    pass "projects mount: host repo usable by $user, writes reach the host"
fi

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

# Agents run in hc terminals, so the shared model URL must reach them.
# shellcheck disable=SC2016 # expands in the hc terminal
sshu 'hc run --bg --name llm -- sh -c "echo llm-url=\${LLAMA_CPP_BASE_URL:-none}; sleep 30"' >/dev/null
llm=
for _ in $(seq 1 30); do
    llm=$(sshu 'hc read llm' | grep -o 'llm-url=[^ ]*' | head -n1 | cut -d= -f2-) || true
    [ -n "$llm" ] && break
    sleep 1
done
sshu 'hc kill llm; hc rm llm' >/dev/null 2>&1 || true
[ "$llm" = "${LLAMA_CPP_URL:-none}" ] || fail "hc terminal LLAMA_CPP_BASE_URL is '$llm', want '${LLAMA_CPP_URL:-none}'"
pass "LLAMA_CPP_BASE_URL in hc terminals (${LLAMA_CPP_URL:-unset})"

if [ -n "$DOTFILES_REPO" ]; then
    sshu 'test -d ~/projects/dotfiles/.git' || fail "dotfiles repo missing"
    if [ -n "$DOTFILES_DIR" ]; then
        # The baked repo is a working tree (uncommitted changes included): compare with
        # the base image's own status rather than expecting a clean tree.
        want=$(docker run --rm "$base" git -C "/home/$user/projects/dotfiles" status --porcelain)
        got=$(sshu 'git -C ~/projects/dotfiles status --porcelain')
        [ "$got" = "$want" ] || fail "bootstrap changed the dotfiles repo:
--- image:
$want
--- box:
$got"
    fi
    # Claude Code LSP plugins the dotfiles enable need the box's language servers.
    enabled=$(sshu 'jq -r ".enabledPlugins // {} | to_entries[] | select(.value) | .key" ~/.claude/settings.json 2>/dev/null' || true)
    installed=$(sshu 'bash -lc "claude plugin list --json"' | jq -r '.[].id')
    for p in rust-analyzer-lsp lua-lsp pyright-lsp typescript-lsp; do
        grep -qxF "$p@claude-plugins-official" <<<"$enabled" || continue
        grep -qxF "$p@claude-plugins-official" <<<"$installed" || fail "enabled claude plugin $p not installed: $installed"
    done
    pass "dotfiles: repo in place and untouched; enabled claude LSP plugins installed"
fi

# --- replace the container with an older home: account, dotfiles, host keys, tools ------
# Make the home look older: owned by another uid, and without the dotfiles repo. The
# next boot must give the account the home's uid and bring the dotfiles back
# (seeded from the base image's /opt/dotfiles, or cloned).
# Only the home volume (-xdev): a mounted ~/projects comes from the host as is.
docker exec "$name" sh -c "cd /home/$user && rm -rf projects/dotfiles && find . -xdev -exec chown -h 1005:1005 {} +"
hostkey=$(ssh-keyscan -p "$port" -t ed25519 127.0.0.1 2>/dev/null | cut -d' ' -f3)
docker rm -f "$name" >/dev/null
start=$(date +%s)
boot
journal=$(docker exec "$name" journalctl -u herdr-box-bootstrap -o cat --no-pager)
# The base image may have the account (it's moved) or not (it's re-created).
grep -qE "user $user: (uid 1005 to match its home|recreated with existing home \(uid 1005\))" <<<"$journal" ||
    fail "account uid does not follow its home's owner"
if [ -n "$DOTFILES_REPO" ]; then
    grep -qE "dotfiles: (seeding|cloning)" <<<"$journal" || fail "dotfiles repo not brought back"
    sshu 'test -d ~/projects/dotfiles/.git' || fail "dotfiles repo missing after replace"
fi
[ "$(ssh-keyscan -p "$port" -t ed25519 127.0.0.1 2>/dev/null | cut -d' ' -f3)" = "$hostkey" ] || fail "host key changed"
smoke >/dev/null || fail "smoke after replace"
pass "replaced container keeps home, host key, tools (boot bootstrap $(($(date +%s) - start))s)"

echo "ALL PASS"
