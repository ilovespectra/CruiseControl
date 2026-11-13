#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product CruiseControlPublisher
BIN="$(swift build -c release --show-bin-path)/CruiseControlPublisher"
APP="build/Cruise Control Publisher.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/CruiseControlPublisher"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>CruiseControlPublisher</string>
<key>CFBundleIdentifier</key><string>com.ilovespectra.cruisecontrol.publisher</string>
<key>CFBundleName</key><string>Cruise Control Publisher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign "${CC_SIGN_IDENTITY:--}" "$APP"
echo "Built $APP. Open it and choose this checkout to launch the web console."
