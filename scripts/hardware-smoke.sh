#!/usr/bin/env bash
# OpenTap hardware smoke test (owner: qa). A guided checklist for a HUMAN with a real iPhone. Not for CI.
#
# Before you start:
#   1. scripts/build-app.sh && open build/OpenTap.app, and finish onboarding (all pills green).
#   2. iPhone plugged in by USB, unlocked, on the Home Screen. Keep it unlocked (Auto-Lock: Never helps).
#   3. Any other iPhone-control app (e.g. ScreenTap) is QUIT: it shares the USB capture and Bluetooth HID.
#   Full plan: docs/TESTING.md > Real iPhone test plan.
#
#   scripts/hardware-smoke.sh [--url http://127.0.0.1:47900/mcp] [--no-calibrate] [--yes]
#
# Each step drives the phone through OpenTap's MCP server, then asks you what happened on the iPhone.
# Answers: y = it worked, n = it didn't (you can type a note), s = skip. A report is saved at the end.
set -uo pipefail
cd "$(dirname "$0")/.."

URL="${OPENTAP_URL:-http://127.0.0.1:47900/mcp}"
CALIBRATE=1
ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) URL="$2"; shift ;;
    --no-calibrate) CALIBRATE=0 ;;
    --yes) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $1 (see --help)"; exit 2 ;;
  esac
  shift
done

OUT="$(mktemp -d "${TMPDIR:-/tmp}/opentap-smoke.XXXXXX")"
REPORT="$OUT/report.txt"
NAMES=(); RESULTS=(); NOTES=()
STEP=0

say() { printf '\n\033[1m[%d] %s\033[0m\n' "$STEP" "$1"; }
info() { printf '    %s\n' "$@"; }

call() { # tool json [image-path] -> prints the tool's text, returns its exit code
  local img=()
  [ -n "${3:-}" ] && img=(--save-image "$3")
  python3 -I scripts/mcp_e2e.py call "$1" "$2" --url "$URL" ${img[@]+"${img[@]}"} > "$OUT/last.txt" 2>&1
  local rc=$?
  sed 's/^/    | /' "$OUT/last.txt" | head -"${LINES_SHOWN:-14}"
  return $rc
}

ask() { # question -> records the step result
  local name="$1" q="$2" a note=""
  if [ "$ASSUME_YES" = 1 ]; then a=y; else
    read -r -p "    $q [y/n/s] " a < /dev/tty
  fi
  case "$a" in
    y|Y|yes) NAMES+=("$name"); RESULTS+=(PASS); NOTES+=("") ;;
    s|S|skip) NAMES+=("$name"); RESULTS+=(SKIP); NOTES+=("") ;;
    *) read -r -p "    What happened instead? " note < /dev/tty
       NAMES+=("$name"); RESULTS+=(FAIL); NOTES+=("$note") ;;
  esac
}

tool_failed() { # name -> records an automatic FAIL with the tool's error
  NAMES+=("$1"); RESULTS+=(FAIL); NOTES+=("tool error: $(grep -m1 -v '^$' "$OUT/last.txt" | cut -c1-120)")
  info "The tool returned an error (above). The 'Fix:' line says what to do; fix it and re-run this script."
}

step() { STEP=$((STEP + 1)); say "$1"; }

cat <<EOF
OpenTap hardware smoke test
  MCP endpoint: $URL
  Output:       $OUT

This drives your real iPhone: it will press Home, open Settings, scroll, type into Search and swipe.
It does not change any setting, delete anything or send messages.
EOF
# Another phone-control app holds the same USB capture device and Bluetooth HID channels.
OTHER="$(pgrep -il 'screentap' 2>/dev/null | grep -vi opentap || true)"
if [ -n "$OTHER" ]; then
  echo
  echo "Another iPhone-control app is running:"; echo "$OTHER" | sed 's/^/    /'
  echo "Why it matters: it holds the iPhone's USB screen capture and the Mac's Bluetooth HID channels, so OpenTap"
  echo "gets no frames or the iPhone sends its input to the other app."
  echo "Fix: quit it from its menu bar icon (don't force-kill it mid-session), relaunch OpenTap, then run this again."
  [ "$ASSUME_YES" = 1 ] || exit 2
fi
if [ "$ASSUME_YES" = 0 ]; then read -r -p "Ready? The iPhone is unlocked on the Home Screen. [y/n] " go < /dev/tty; [ "$go" = y ] || exit 0; fi

# --- 1. Server + status --------------------------------------------------------------------------
step "MCP server and status"
LINES_SHOWN=12 call status '{}'
case $? in
  2) info "OpenTap isn't answering. Open OpenTap.app (and finish onboarding), then run this again."; exit 2 ;;
  0) ask "status" "Does this match the OpenTap window (USB, Screen, Bluetooth, AssistiveTouch all green)?" ;;
  *) tool_failed "status" ;;
esac

# --- 2. Screenshot ---------------------------------------------------------------------------------
step "Screenshot"
LINES_SHOWN=20 call screenshot '{"include_text":true}' "$OUT/screenshot-1.jpg"
if [ $? -eq 0 ]; then
  info "Saved $OUT/screenshot-1.jpg - opening it in Preview."
  [ "$ASSUME_YES" = 0 ] && { open "$OUT/screenshot-1.jpg" 2>/dev/null || true; }
  ask "screenshot" "Does the image show exactly what is on the iPhone right now (not stretched, not rotated)?"
  ask "ocr" "Is the text list above what you see on screen, roughly where it is (top = small y)?"
else tool_failed "screenshot"; fi

# --- 3. Home ---------------------------------------------------------------------------------------
step "Home button (consumer AC Home / cmd+H)"
LINES_SHOWN=4 call press_key '{"key":"home"}'
if [ $? -eq 0 ]; then ask "home" "Did the iPhone go to the Home Screen?"; else tool_failed "home"; fi

# --- 4. Calibration --------------------------------------------------------------------------------
if [ "$CALIBRATE" = 1 ]; then
  step "Calibration (about 30 s; don't touch the iPhone)"
  info "Watch the pointer dot: it should park in the top-left corner and move in straight lines."
  LINES_SHOWN=4 call calibrate '{}'
  if [ $? -eq 0 ]; then ask "calibrate" "Did the pointer move around and end near the centre of the screen?"; else tool_failed "calibrate"; fi
fi

# --- 5. Spotlight + typing --------------------------------------------------------------------------
step "Keyboard: cmd+space opens Search, then typing"
LINES_SHOWN=3 call press_key '{"key":"cmd+space"}'
if [ $? -eq 0 ]; then
  LINES_SHOWN=8 call type_text '{"text":"OpenTap test 123"}'
  if [ $? -eq 0 ]; then ask "typing" "Is Search open with exactly \"OpenTap test 123\" typed in it?"; else tool_failed "typing"; fi
else tool_failed "spotlight"; fi
LINES_SHOWN=2 call press_key '{"key":"escape"}' >/dev/null
LINES_SHOWN=2 call press_key '{"key":"home"}' >/dev/null

# --- 6. open_app -----------------------------------------------------------------------------------
step "open_app Settings (Home + Search + type + return)"
LINES_SHOWN=10 call open_app '{"name":"Settings"}'
if [ $? -eq 0 ]; then ask "open_app" "Did the Settings app open?"; else tool_failed "open_app"; fi

# --- 7. Scroll -------------------------------------------------------------------------------------
step "Scroll down then up"
LINES_SHOWN=6 call scroll '{"direction":"down","amount":0.6}'
if [ $? -eq 0 ]; then ask "scroll down" "Did the Settings list scroll down by about half a screen?"; else tool_failed "scroll down"; fi
LINES_SHOWN=4 call scroll '{"direction":"up","amount":1.0}'
if [ $? -eq 0 ]; then ask "scroll up" "Is it back at the top?"; else tool_failed "scroll up"; fi

# --- 8. tap_text ------------------------------------------------------------------------------------
step "tap_text \"General\" (pointer + click accuracy)"
LINES_SHOWN=8 call tap_text '{"text":"General"}'
if [ $? -eq 0 ]; then ask "tap_text" "Did Settings > General open (the pointer landed on the row)?"; else tool_failed "tap_text"; fi

# --- 9. Swipes --------------------------------------------------------------------------------------
step "Swipe from the left edge (Back)"
W=$(grep -oE 'Screenshot [0-9]+x[0-9]+' "$OUT/last.txt" | head -1 | grep -oE '[0-9]+x[0-9]+')
SW=${W%x*}; SH=${W#*x}; SW=${SW:-590}; SH=${SH:-1280}
LINES_SHOWN=4 call swipe "{\"from_x\":3,\"from_y\":$((SH / 2)),\"to_x\":$((SW * 3 / 4)),\"to_y\":$((SH / 2)),\"duration_ms\":400}"
if [ $? -eq 0 ]; then ask "swipe back" "Did it go back to the main Settings list?"; else tool_failed "swipe back"; fi

step "Swipe up from the bottom edge (Home)"
LINES_SHOWN=4 call swipe "{\"from_x\":$((SW / 2)),\"from_y\":$((SH - 4)),\"to_x\":$((SW / 2)),\"to_y\":$((SH / 3)),\"duration_ms\":300}"
if [ $? -eq 0 ]; then ask "swipe home" "Did the iPhone go to the Home Screen?"; else tool_failed "swipe home"; fi

# --- 10. Tap accuracy -------------------------------------------------------------------------------
step "tap at a point (tap the 2nd app icon label)"
LINES_SHOWN=0 call screenshot '{"include_text":true}' "$OUT/screenshot-2.jpg" >/dev/null
TARGET=$(grep -E '^"[^"]+" \([0-9]+, [0-9]+\)$' "$OUT/last.txt" | sed -n '3p')
if [ -n "$TARGET" ]; then
  X=$(echo "$TARGET" | sed -E 's/.*\(([0-9]+), ([0-9]+)\)$/\1/'); Y=$(echo "$TARGET" | sed -E 's/.*\(([0-9]+), ([0-9]+)\)$/\2/')
  info "Tapping $TARGET"
  LINES_SHOWN=4 call tap "{\"x\":$X,\"y\":$Y}"
  if [ $? -eq 0 ]; then ask "tap" "Did $(echo "$TARGET" | sed -E 's/ \(.*//') open?"; else tool_failed "tap"; fi
  LINES_SHOWN=2 call press_key '{"key":"home"}' >/dev/null
else
  info "No text found on the Home Screen to tap; skipping."
  NAMES+=("tap"); RESULTS+=(SKIP); NOTES+=("no OCR text on home screen")
fi

# --- 11. Long press ----------------------------------------------------------------------------------
step "long_press on an app icon (should open its quick-actions menu)"
if [ -n "${X:-}" ] && [ -n "${Y:-}" ]; then
  LINES_SHOWN=4 call long_press "{\"x\":$X,\"y\":$((Y - 40)),\"duration_ms\":900}"
  if [ $? -eq 0 ]; then ask "long_press" "Did a menu (or jiggle mode) appear for that icon?"; else tool_failed "long_press"; fi
  LINES_SHOWN=2 call press_key '{"key":"escape"}' >/dev/null
  LINES_SHOWN=2 call press_key '{"key":"home"}' >/dev/null
else
  NAMES+=("long_press"); RESULTS+=(SKIP); NOTES+=("no icon position from step 10")
fi

# --- 12. Batch ---------------------------------------------------------------------------------------
step "batch: Home, Search, type \"Settings\", return"
LINES_SHOWN=6 call batch '{"actions":[{"action":"press_key","key":"home"},{"action":"press_key","key":"cmd+space"},{"action":"type_text","text":"Settings"},{"action":"press_key","key":"return"}]}'
if [ $? -eq 0 ]; then ask "batch" "Did Settings open in one go?"; else tool_failed "batch"; fi
LINES_SHOWN=2 call press_key '{"key":"home"}' >/dev/null

# --- Report -----------------------------------------------------------------------------------------
{
  echo "OpenTap hardware smoke test - $(date)"
  echo "Endpoint: $URL"
  echo "macOS: $(sw_vers -productVersion 2>/dev/null)  Mac: $(sysctl -n hw.model 2>/dev/null)"
  echo
  W=12; for n in "${NAMES[@]}"; do [ ${#n} -gt $W ] && W=${#n}; done
  for i in "${!NAMES[@]}"; do printf '%-*s  %-4s  %s\n' "$W" "${NAMES[$i]}" "${RESULTS[$i]}" "${NOTES[$i]}"; done
} > "$REPORT"
echo; cat "$REPORT"; echo
echo "Report: $REPORT (screenshots in $OUT). Attach it to the issue/PR."
grep -q "  FAIL  " "$REPORT" && exit 1
exit 0
