#!/bin/bash
# Stops and removes the launchd agents installed by install-services.sh. Data is kept.
set -uo pipefail
for label in com.cookbook.api com.cookbook.minio com.cookbook.backup com.cookbook.cleanup; do
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null && echo "stopped $label"
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
