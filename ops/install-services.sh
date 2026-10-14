#!/bin/bash
# Installs launchd agents so the backend runs whenever you're logged in:
#   com.cookbook.minio    photo storage (keep alive)
#   com.cookbook.api      FastAPI (keep alive)
#   com.cookbook.backup   pg_dump nightly at 03:30
#   com.cookbook.cleanup  hourly
# PostgreSQL and Ollama run as Homebrew services already. Undo: ops/uninstall-services.sh
set -euo pipefail
OPS="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
LOGS="$HOME/Library/Logs/Cookbook"
mkdir -p "$AGENTS" "$LOGS"
chmod +x "$OPS"/*.sh

plist() { # label script keepalive(true|false) schedule-xml
  cat > "$AGENTS/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>$OPS/$2</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin</string></dict>
  <key>StandardOutPath</key><string>$LOGS/$1.log</string>
  <key>StandardErrorPath</key><string>$LOGS/$1.log</string>
  <key>RunAtLoad</key><$3/>
  <key>KeepAlive</key><$3/>
  <key>ThrottleInterval</key><integer>10</integer>
  $4
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$1" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENTS/$1.plist"
  echo "loaded $1"
}

plist com.cookbook.minio run-minio.sh true ""
plist com.cookbook.api run-api.sh true ""
plist com.cookbook.backup backup.sh false "<key>StartCalendarInterval</key><dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>30</integer></dict>"
plist com.cookbook.cleanup cleanup.sh false "<key>StartInterval</key><integer>3600</integer>"
echo "Logs: $LOGS"
