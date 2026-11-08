#!/usr/bin/env bash
# For a human with an iPhone plugged in and OpenTap.app running (onboarding done).
# Calls the live MCP server: status, screenshot, home, open Settings.
set -euo pipefail
URL="${OPENTAP_URL:-http://127.0.0.1:47900/mcp}"
H=$(mktemp)
curl -sf -D "$H" "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' >/dev/null
SID=$(grep -i '^mcp-session-id:' "$H" | awk '{print $2}' | tr -d '\r')
call() { echo "== $1"; curl -sf "$URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $SID" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}" | head -c 600; echo; }
call status '{}'
call screenshot '{"include_text":true}'
call press_key '{"key":"home"}'
call open_app '{"name":"Settings"}'
