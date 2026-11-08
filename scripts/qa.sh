#!/usr/bin/env bash
# Build + unit tests + mock MCP smoke test. Never touches real hardware.
# Usage: scripts/qa.sh [scratch-path]   (default .build-qa)
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${1:-.build-qa}"
PORT="${OPENTAP_MOCK_PORT:-47999}"
swift build --scratch-path "$SCRATCH"
swift test --scratch-path "$SCRATCH"
BIN="$(swift build --scratch-path "$SCRATCH" --show-bin-path)/opentap-mock"
"$BIN" --port "$PORT" & PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
URL="http://127.0.0.1:$PORT/mcp"
for _ in $(seq 1 50); do curl -s -o /dev/null "$URL" -X POST -d '{}' && break; sleep 0.1; done
H=$(mktemp)
curl -sf -D "$H" "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"qa","version":"0"}}}' >/dev/null
SID=$(grep -i '^mcp-session-id:' "$H" | awk '{print $2}' | tr -d '\r')
call() { curl -sf "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $SID" -d "$1"; }
call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | grep -q '"tap_text"'
call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"status","arguments":{}}}' | grep -q '"result"'
echo "QA passed"
