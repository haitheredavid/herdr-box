#!/bin/sh
# Log omp in to a model provider on the box from this machine's browser.
# omp's OAuth logins redirect the browser to a fixed loopback port; this forwards
# that port from here to the box, so the redirect reaches omp's listener there.
# Device-code and API-key providers need no forward and work the same way.
#
# Usage: scripts/login.sh <ssh-host> [provider]   e.g. herdr-box anthropic
#   no provider: omp's picker, with every known callback port forwarded
#   HERDR_SSH_OPTS  extra ssh options (word-split)
set -eu

[ $# -ge 1 ] && [ $# -le 2 ] || {
    echo "usage: scripts/login.sh <ssh-host> [provider]" >&2
    exit 2
}
host=$1
provider=${2:-}
case $provider in *[!a-z0-9-]*)
    echo "herdr-box: invalid provider id '$provider'" >&2
    exit 2
    ;;
esac

# Callback ports from omp's auth registry (omp://auth-broker-gateway.md).
port_of() {
    case $1 in
        anthropic) echo 54545 ;;
        openai-codex) echo 1455 ;;
        google-gemini-cli) echo 8085 ;;
        google-antigravity) echo 51121 ;;
        devin) echo 59653 ;;
        openrouter) echo 54549 ;;
        stencil) echo 54547 ;;
    esac
}

if [ -n "$provider" ]; then
    port=$(port_of "$provider")
    # A busy local port would break the redirect, so fail fast instead.
    fwd=${port:+-L $port:127.0.0.1:$port -o ExitOnForwardFailure=yes}
else
    fwd=
    for p in anthropic openai-codex google-gemini-cli google-antigravity devin openrouter stencil; do
        port=$(port_of "$p")
        fwd="$fwd -L $port:127.0.0.1:$port"
    done
    port=
    echo "herdr-box: after picking, open omp's 'Local shortcut' link (http://localhost:<port>/launch) here; don't copy the long URL" >&2
fi

# omp serves /launch, a short redirect to the full authorize URL. Copying the
# long URL out of a wrapped terminal truncates it ("Missing redirect_uri"), so
# open the short one in this machine's browser once omp listens behind the forward.
if [ -n "${port:-}" ]; then
    echo "herdr-box: opening http://localhost:$port/launch in your browser once omp is ready" >&2
    (
        for _ in $(seq 1 60); do
            # 000 = forward up but nothing listening on the box yet.
            code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/") || true
            if [ "${code:-000}" != 000 ]; then
                open "http://localhost:$port/launch" 2>/dev/null ||
                    echo "herdr-box: open http://localhost:$port/launch in your browser" >&2
                exit 0
            fi
            sleep 1
        done
    ) &
fi

# shellcheck disable=SC2086 # forwards and opts are word-split on purpose
exec ssh -t $fwd ${HERDR_SSH_OPTS:-} "$host" "bash -lc 'omp login $provider'"
