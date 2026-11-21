#!/usr/bin/env bash
# PocketPilot QA gate (owner: qa). Never touches real hardware: everything runs against the simulated iPhone.
#
#   scripts/qa.sh                 build + unit/integration tests + MCP end-to-end against pocketpilot-mock
#   scripts/qa.sh --strict        also fail integration tests whose module is still a stub (integrator mode)
#   scripts/qa.sh --no-tests      skip `swift test` (build + MCP end-to-end only)
#   scripts/qa.sh --filter NAME   pass a test filter to `swift test` (e.g. MockDeviceTests)
#   scripts/qa.sh --scratch DIR   SwiftPM scratch path (default .build; use your own when builds run in parallel)
#   scripts/qa.sh --port N        first port for pocketpilot-mock (default 47990; fault scenarios use N+1...)
#
# Prints a PASS/FAIL table and exits non-zero if anything failed.
set -uo pipefail
cd "$(dirname "$0")/.."

SCRATCH=".build"
PORT="${POCKETPILOT_QA_PORT:-47990}"
RUN_TESTS=1
STRICT=0
FILTER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --no-tests) RUN_TESTS=0 ;;
    --filter) FILTER="$2"; shift ;;
    --scratch) SCRATCH="$2"; shift ;;
    --port) PORT="$2"; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) # backwards compatible: a bare argument is the scratch path
       SCRATCH="$1" ;;
  esac
  shift
done

LOGDIR="$(mktemp -d "${TMPDIR:-/tmp}/pocketpilot-qa.XXXXXX")"
NAMES=(); RESULTS=(); NOTES=()
record() { NAMES+=("$1"); RESULTS+=("$2"); NOTES+=("$3"); }
MOCK_PIDS=()
cleanup() { for p in "${MOCK_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

bold() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# 1. Build -------------------------------------------------------------------------------------------
bold "swift build --scratch-path $SCRATCH"
swift build --scratch-path "$SCRATCH" > "$LOGDIR/build.log" 2>&1; BUILD_RC=$?
grep -E "error:" "$LOGDIR/build.log" | sort -u | head -20
tail -1 "$LOGDIR/build.log"
if [ $BUILD_RC -eq 0 ]; then
  record "build" PASS ""
else
  record "build" FAIL "$(grep -m3 'error:' "$LOGDIR/build.log" | sed 's/^.*Sources\///' | tr '\n' ' ' | cut -c1-160)"
fi

BIN_DIR="$(swift build --scratch-path "$SCRATCH" --show-bin-path 2>/dev/null)"
MOCK="$BIN_DIR/pocketpilot-mock"

# 2. Tests -------------------------------------------------------------------------------------------
if [ "$RUN_TESTS" = 1 ] && [ "${RESULTS[0]}" = PASS ]; then
  bold "swift test --scratch-path $SCRATCH${FILTER:+ --filter $FILTER}"
  export POCKETPILOT_STRICT_INTEGRATION=$STRICT
  if [ -n "$FILTER" ]; then
    swift test --scratch-path "$SCRATCH" --filter "$FILTER" > "$LOGDIR/test.log" 2>&1; TEST_RC=$?
  else
    swift test --scratch-path "$SCRATCH" > "$LOGDIR/test.log" 2>&1; TEST_RC=$?
  fi
  grep -E "error:|' failed|skipped|Executed .* tests" "$LOGDIR/test.log" | grep -v "^Test Suite" | tail -40
  SUMMARY="$(grep -E 'Executed [0-9]+ tests' "$LOGDIR/test.log" | tail -1 | sed 's/^[[:space:]]*//')"
  SKIPPED="$(grep -cE "^Test Case .* skipped" "$LOGDIR/test.log" || true)"
  FAILED_TESTS="$(grep -E "^Test Case .* failed" "$LOGDIR/test.log" | sed -E "s/.*\[PocketPilotCoreTests\.([A-Za-z]+) ([A-Za-z0-9_]+)\].*/\1.\2/" | sort -u)"
  if [ $TEST_RC -eq 0 ]; then
    record "swift test" PASS "$SUMMARY; $SKIPPED skipped"
  else
    record "swift test" FAIL "${SUMMARY:-did not finish (see $LOGDIR/test.log)}"
    while IFS= read -r t; do [ -n "$t" ] && record "  $t" FAIL ""; done <<< "$FAILED_TESTS"
  fi
elif [ "$RUN_TESTS" = 1 ]; then
  record "swift test" SKIP "build failed"
fi

# 3. MCP end-to-end against pocketpilot-mock ------------------------------------------------------------
start_mock() { # port, extra args...  -> sets MOCK_PID, returns 0 when listening
  local port="$1"; shift
  local log="$LOGDIR/mock-$port.log"
  "$MOCK" --port "$port" --quiet "$@" > "$log" 2>&1 &
  MOCK_PID=$!
  MOCK_PIDS+=("$MOCK_PID")
  for _ in $(seq 1 100); do
    grep -q "listening on" "$log" 2>/dev/null && return 0
    kill -0 "$MOCK_PID" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

run_e2e() { # name, port, mock args (quoted string), e2e args...
  local name="$1" port="$2" margs="$3"; shift 3
  if [ ! -x "$MOCK" ]; then record "$name" SKIP "no pocketpilot-mock binary"; return; fi
  # shellcheck disable=SC2086
  if ! start_mock "$port" $margs; then
    record "$name" FAIL "pocketpilot-mock didn't start: $(tail -2 "$LOGDIR/mock-$port.log" | tr '\n' ' ' | cut -c1-140)"
    return
  fi
  # Probe with curl first so a dead socket shows up as such.
  if ! curl -s -o /dev/null -m 3 -X POST "http://127.0.0.1:$port/mcp" -H 'Content-Type: application/json' -d '{}'; then
    record "$name" FAIL "nothing answers on 127.0.0.1:$port"
  elif python3 -I scripts/mcp_e2e.py --url "http://127.0.0.1:$port/mcp" "$@" > "$LOGDIR/e2e-$port.log" 2>&1; then
    record "$name" PASS "$(grep -E '^[0-9]+ passed' "$LOGDIR/e2e-$port.log")"
  else
    record "$name" FAIL "$(grep -E '^[0-9]+ passed' "$LOGDIR/e2e-$port.log")"
    while IFS= read -r line; do
      record "  ${line%%: *}" FAIL "$(echo "${line#*: }" | cut -c1-150)"
    done < <(grep -E "^  FAILED " "$LOGDIR/e2e-$port.log" | sed -E 's/^  FAILED //')
  fi
  grep -E '^  (PASS|FAIL) ' "$LOGDIR/e2e-$port.log"
  kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null
}

if [ "${RESULTS[0]}" = PASS ]; then
  bold "MCP end-to-end (pocketpilot-mock on :$PORT)"
  run_e2e "mcp e2e (mock phone)" "$PORT" ""
  bold "MCP fault scenarios"
  run_e2e "fault: no-bluetooth" "$((PORT + 1))" "--fault no-bluetooth" --scenario no-bluetooth
  run_e2e "fault: at-off" "$((PORT + 2))" "--fault at-off" --scenario at-off
  run_e2e "fault: no-frames" "$((PORT + 3))" "--fault no-frames" --scenario no-frames
else
  record "mcp e2e (mock phone)" SKIP "build failed"
fi

# 4. Table -------------------------------------------------------------------------------------------
W=10; for n in "${NAMES[@]}"; do [ ${#n} -gt $W ] && W=${#n}; done
LINE="+-$(printf '%*s' "$W" '' | tr ' ' '-')-+------+"
printf '\n%s\n| %-*s | %-4s |\n%s\n' "$LINE" "$W" "PocketPilot QA" "" "$LINE"
FAILS=0
for i in "${!NAMES[@]}"; do
  printf '| %-*s | %-4s | %s\n' "$W" "${NAMES[$i]}" "${RESULTS[$i]}" "${NOTES[$i]}"
  [ "${RESULTS[$i]}" = FAIL ] && FAILS=$((FAILS + 1))
done
printf '%s\n' "$LINE"
echo "Logs: $LOGDIR"
if [ $FAILS -gt 0 ]; then echo "QA FAILED ($FAILS failing rows)"; exit 1; fi
echo "QA PASSED"
