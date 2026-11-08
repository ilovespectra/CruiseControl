#!/usr/bin/env bash
# Builds "Cruise Control.app" into ./build.
#   --install    copy to /Applications and register a LaunchAgent (starts at login, restarts after crashes)
#   --uninstall  remove the LaunchAgent and the installed app
#
# Signing: uses $CC_SIGN_IDENTITY, else the first valid code-signing identity in your keychain,
# else ad-hoc. A stable identity keeps macOS Accessibility / Screen Recording grants across rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_ARGS=(--arch "$(uname -m)")
if [[ "${CC_UNIVERSAL:-0}" == "1" ]]; then
  for ARCH in arm64 x86_64; do
    swift build -c release --product CruiseControl --arch "$ARCH" --scratch-path ".build-$ARCH"
  done
  ARM_BIN="$(swift build -c release --show-bin-path --arch arm64 --scratch-path .build-arm64)/CruiseControl"
  INTEL_BIN="$(swift build -c release --show-bin-path --arch x86_64 --scratch-path .build-x86_64)/CruiseControl"
  mkdir -p .build/universal
  lipo -create "$ARM_BIN" "$INTEL_BIN" -output .build/universal/CruiseControl
  BIN=".build/universal/CruiseControl"
else
  swift build -c release --product CruiseControl "${ARCH_ARGS[@]}"
  BIN="$(swift build -c release --show-bin-path "${ARCH_ARGS[@]}")/CruiseControl"
fi

APP="build/Cruise Control.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CruiseControl"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${CC_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $CC_VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${CC_BUILD:?CC_BUILD is required}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CruiseControlSourceCommit string ${CC_SOURCE_COMMIT:?CC_SOURCE_COMMIT is required}" "$APP/Contents/Info.plist"
fi
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/*.ttf Resources/Fonts/OFL-*.txt "$APP/Contents/Resources/Fonts/"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${CC_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/ {print $2; exit}')"
fi
SIGN_ARGS=(--force)
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
  SIGN_ARGS=(--force --options runtime --timestamp)
fi
codesign "${SIGN_ARGS[@]}" --sign "${IDENTITY:--}" --identifier com.ilovespectra.cruisecontrol "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
  LABEL="com.ilovespectra.cruisecontrol"
  AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
  DOMAIN="gui/$(id -u)"

  launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  osascript -e "tell application id \"$LABEL\" to quit" >/dev/null 2>&1 || true
  sleep 1
  rm -rf "/Applications/Cruise Control.app"
  cp -R "$APP" /Applications/

  # Always running: launchd restarts it however it exits. It's invisible unless HeyClicky is open.
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/Cruise Control.app/Contents/MacOS/CruiseControl</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>5</integer>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
PLIST
  launchctl bootstrap "$DOMAIN" "$AGENT"
  echo "Installed to /Applications and started via LaunchAgent ($AGENT)"
fi

if [[ "${1:-}" == "--uninstall" ]]; then
  LABEL="com.ilovespectra.cruisecontrol"
  launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
  rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
  rm -rf "/Applications/Cruise Control.app"
  echo "Uninstalled (config left in ~/Library/Application Support/CruiseControl)"
fi
