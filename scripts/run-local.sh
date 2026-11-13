#!/usr/bin/env bash
# Incrementally build and launch Cruise Control from this checkout. Never installs or touches /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c debug --product CruiseControl
BIN="$(swift build -c debug --show-bin-path)/CruiseControl"
APP="$PWD/build/local/Cruise Control Local.app"
BINARY="$APP/Contents/MacOS/CruiseControl"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$BINARY"
cp -R "$(dirname "$BIN")/CruiseControl_CruiseControl.bundle" "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL-*.txt "$APP/Contents/Resources/Fonts/"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
test -x "$BINARY"
export CRUISE_LOCAL_TEST=1
export CRUISE_LOCAL_CONFIG_DIR="${CRUISE_LOCAL_CONFIG_DIR:-$PWD/build/local-state}"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${CC_LOCAL_VERSION:-1.1.2}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${CC_BUILD:-1}" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.ilovespectra.cruisecontrol.local" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Cruise Control Local" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Cruise Control Local" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CruiseControlLocalTesting bool true" "$APP/Contents/Info.plist"
IDENTITY="${CC_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'\"' '/\"/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" --identifier com.ilovespectra.cruisecontrol.local "$APP"
printf 'Launching local checkout (no install): %s\n' "$APP"
printf 'Isolated settings and delivery history: %s\n' "$CRUISE_LOCAL_CONFIG_DIR"
printf 'Debug build: stop this VS Code task, then rerun it after edits. No installer or release build is involved.\n'
exec "$BINARY"
