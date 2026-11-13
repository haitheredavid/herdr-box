#!/bin/sh
# Smoke check the box over SSH, the way Herdr clients connect.
#
# Usage: scripts/smoke.sh <ssh-target>      e.g. herdr-box (an ~/.ssh/config Host)
#   HERDR_SSH_OPTS  extra ssh options (word-split), e.g. "-p 2298 -i key"
set -eu

[ $# -eq 1 ] || {
    echo "usage: scripts/smoke.sh <ssh-target>" >&2
    exit 2
}
target=$1

# shellcheck disable=SC2086 # HERDR_SSH_OPTS is intentionally word-split
s() { ssh -o BatchMode=yes ${HERDR_SSH_OPTS:-} "$target" "$@"; }

fail() {
    echo "herdr-box smoke: $*" >&2
    exit 1
}

out=$(s true) || fail "ssh login to $target failed"
[ -z "$out" ] || fail "non-interactive login printed output (breaks herdr): $out"

s herdr-core --version >/dev/null || fail "herdr-core not runnable over ssh"
s herdr --version >/dev/null || fail "herdr not runnable over ssh"

# The terminal reports which tools and language servers its environment resolves:
# agents and editors inherit it (helix, omp, and Claude Code's LSP plugins look the
# servers up on PATH). The lists live in config/checks.txt, shared with test/run.sh.
checks=$(dirname "$0")/../config/checks.txt
[ -f "$checks" ] || fail "missing $checks"
tools=$(awk '$1 == "tool" || $1 == "tool-amd64" { printf "%s ", $2 }' "$checks")
lsps=$(awk '$1 == "lsp" { printf "%s ", $2 }' "$checks")
# shellcheck disable=SC2016 # $t must expand in the remote terminal, not here
s 'hc run --bg --name smoke -- sh -c "echo herdr-smoke-ok; for t in '"$tools"'; do command -v \$t >/dev/null && printf \"tool:%s \" \$t; done; echo; for t in '"$lsps"'; do command -v \$t >/dev/null || printf \"lsp-missing:%s \" \$t; done; echo lsp-checked; sleep 60"' >/dev/null ||
    fail "hc run failed"
# Poll until the terminal has finished its checks: a cold mise shim cache can be slow.
screen=
i=0
while [ "$i" -lt 30 ]; do
    screen=$(s hc read smoke) || screen=
    case $screen in *lsp-checked*) break ;; esac
    i=$((i + 1))
    sleep 2
done
s hc kill smoke >/dev/null 2>&1 || true
s hc rm smoke >/dev/null 2>&1 || true
echo "$screen" | grep -q herdr-smoke-ok || fail "hc terminal output not readable from a second ssh session"

# shellcheck disable=SC2088 # literal path in the message, expanded remotely in the test
s 'test -w ~/projects' || fail "~/projects not writable"

# The shared model server (box.conf LLAMA_CPP_URL) is reported, not required: its
# Mac may be asleep.
# shellcheck disable=SC2016 # expands on the box
llm=$(s 'bash -lc "[ -n \"\${LLAMA_CPP_BASE_URL:-}\" ] || { echo none; exit 0; }; curl -sf -m 5 \"\$LLAMA_CPP_BASE_URL/health\" >/dev/null && echo ok || echo unreachable"') || llm=unknown

found=$(echo "$screen" | grep -o 'tool:[a-z]*' | cut -d: -f2 | tr '\n' ' ')
echo "$screen" | grep -q lsp-checked || fail "hc terminal did not finish the language server check"
missing=$(echo "$screen" | grep -o 'lsp-missing:[a-z-]*' | cut -d: -f2 | tr '\n' ' ')
echo "herdr-box smoke ok ($target): hc terminals see: ${found:-no tools}; language servers missing: ${missing:-none}; llm: $llm"
