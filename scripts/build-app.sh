#!/usr/bin/env bash
# Builds OpenTap.app (release), embeds Info.plist with usage strings, ad-hoc signs it.
# Usage: scripts/build-app.sh [scratch-path]   (default .build-app)
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="${1:-.build-app}"
swift build -c release --product OpenTap --scratch-path "$SCRATCH"
BIN="$(swift build -c release --product OpenTap --scratch-path "$SCRATCH" --show-bin-path)/OpenTap"
APP="build/OpenTap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/OpenTap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/" || true
codesign --force --deep --sign - "$APP"
echo "Built $APP"
