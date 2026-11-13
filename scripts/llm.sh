#!/bin/sh
# Run the shared llama.cpp model server on this Mac (Metal) and serve it to the
# tailnet, for herdr boxes (box.conf LLAMA_CPP_URL; omp discovers it there).
# llama-server runs as a LaunchAgent on loopback; `tailscale serve` exposes it.
#
# Usage: scripts/llm.sh up|down|status
#   LLM_HF          Hugging Face model (repo:quant), downloaded on first start
#   LLM_PORT        tailnet port boxes connect to (default 8080)
#   LLM_LOCAL_PORT  llama-server's loopback port (default 18080)
set -eu

LLM_HF=${LLM_HF:-bartowski/Meta-Llama-3.1-8B-Instruct-GGUF:Q4_K_M}
LLM_PORT=${LLM_PORT:-8080}
LLM_LOCAL_PORT=${LLM_LOCAL_PORT:-18080}
label=dev.herdr-box.llama-server
plist=$HOME/Library/LaunchAgents/$label.plist
log=$HOME/Library/Logs/herdr-box-llm.log
uid=$(id -u)

die() {
    echo "herdr-box: $*" >&2
    exit 1
}

healthy() { curl -sf -m 2 "http://127.0.0.1:$LLM_LOCAL_PORT/health" >/dev/null 2>&1; }

up() {
    [ "$(uname -s)" = Darwin ] || die "llm.sh runs on the Mac that hosts the model"
    command -v brew >/dev/null || die "Homebrew not found; install it first (https://brew.sh)"
    command -v jq >/dev/null || die "jq not found; install it (brew install jq)"
    if ! command -v llama-server >/dev/null; then
        echo "herdr-box: installing llama.cpp (brew)" >&2
        brew install llama.cpp
    fi
    server=$(command -v llama-server)
    tailscale status >/dev/null 2>&1 || die "tailscale is not running on this Mac; start it (tailscale up) first"

    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    cat >"$tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$server</string>
    <string>-hf</string><string>$LLM_HF</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>$LLM_LOCAL_PORT</string>
    <string>-c</string><string>65536</string>
    <string>-np</string><string>2</string>
    <string>--jinja</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
EOF
    # Unchanged and loaded: leave it running (other boxes may be using it).
    if ! { cmp -s "$tmp" "$plist" && launchctl print "gui/$uid/$label" >/dev/null 2>&1; }; then
        mkdir -p "$HOME/Library/LaunchAgents"
        mv "$tmp" "$plist"
        launchctl bootout "gui/$uid/$label" 2>/dev/null || true
        launchctl bootstrap "gui/$uid" "$plist"
    fi

    if ! healthy; then
        echo "herdr-box: waiting for llama-server (first start downloads the model; log: $log)" >&2
        waited=0
        until healthy; do
            [ "$waited" -lt 900 ] || die "llama-server not healthy after 15 min; see $log"
            sleep 5
            waited=$((waited + 5))
        done
    fi

    tailscale serve --bg --http "$LLM_PORT" "127.0.0.1:$LLM_LOCAL_PORT" >/dev/null
    dns=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
    echo "herdr-box: llm ready: set LLAMA_CPP_URL=\"http://$dns:$LLM_PORT\" in boxes/<name>/box.conf, then mise run deploy"
}

down() {
    if ! tailscale serve --http "$LLM_PORT" off >/dev/null 2>&1; then
        # Older clients lack `off`: reset only when this port is the whole serve config.
        others=$(tailscale serve status --json 2>/dev/null |
            jq -r --arg p "$LLM_PORT" '[(.TCP // {}) | keys[] | select(. != $p)] | length') || others=unknown
        [ "$others" = 0 ] ||
            die "could not remove the tailnet serve on port $LLM_PORT; run: tailscale serve --http $LLM_PORT off"
        tailscale serve reset
    fi
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    rm -f "$plist"
    echo "herdr-box: llm stopped (the model stays in llama.cpp's cache)"
}

status() {
    if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
        echo "launchd: $label loaded"
    else
        echo "launchd: $label not loaded"
    fi
    if healthy; then
        echo "health: ok (127.0.0.1:$LLM_LOCAL_PORT)"
    else
        echo "health: not responding (127.0.0.1:$LLM_LOCAL_PORT; log: $log)"
    fi
    tailscale serve status || true
}

case ${1:-} in
    up) up ;;
    down) down ;;
    status) status ;;
    *)
        echo "usage: scripts/llm.sh up|down|status" >&2
        exit 2
        ;;
esac
