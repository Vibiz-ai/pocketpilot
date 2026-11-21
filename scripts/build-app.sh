#!/usr/bin/env bash
# Builds build/PocketPilot.app (release), embeds Info.plist with the Camera/Bluetooth usage strings
# and ad-hoc signs it. Does not launch the app.
# Usage: scripts/build-app.sh [scratch-path]   (default .build-app)
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${1:-.build-app}"
PLIST="Resources/Info.plist"

plutil -lint "$PLIST" >/dev/null
for key in CFBundleIdentifier NSCameraUsageDescription NSBluetoothAlwaysUsageDescription LSMinimumSystemVersion; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 || {
    echo "build-app: $PLIST is missing $key. Add it back; macOS refuses the permission prompt without the usage strings." >&2
    exit 1
  }
done

swift build -c release --product PocketPilot --scratch-path "$SCRATCH"
BIN="$(swift build -c release --product PocketPilot --scratch-path "$SCRATCH" --show-bin-path)/PocketPilot"
APP="build/PocketPilot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PocketPilot"
cp "$PLIST" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"), ad-hoc signed)"
