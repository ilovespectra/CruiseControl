#!/bin/bash
set -euo pipefail
LABEL="com.ilovespectra.cruisecontrol"
USER_NAME="$(stat -f %Su /dev/console)"
if [[ "$USER_NAME" == "root" || "$USER_NAME" == "loginwindow" ]]; then
  echo "Open Cruise Control after login to finish startup setup."
  exit 0
fi
USER_ID="$(id -u "$USER_NAME")"
USER_HOME="$(dscl . -read "/Users/$USER_NAME" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')"
AGENT_DIR="$USER_HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/$LABEL.plist"
launchctl bootout "gui/$USER_ID/$LABEL" 2>/dev/null || true
mkdir -p "$AGENT_DIR"
if [[ -L "$AGENT_DIR" || -L "$AGENT" ]]; then
  echo "Refusing to overwrite a symlinked LaunchAgent path." >&2
  exit 1
fi
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>/Applications/Cruise Control.app/Contents/MacOS/CruiseControl</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>5</integer>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
chown "$USER_ID" "$AGENT"
chmod 644 "$AGENT"
launchctl bootstrap "gui/$USER_ID" "$AGENT"
