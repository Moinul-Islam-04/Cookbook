#!/bin/bash
# Nightly PostgreSQL backup (custom format; restore with pg_restore). Keeps 14 days.
# Photos live in ~/Library/Application Support/Cookbook/minio; include that folder in
# Time Machine to back them up too.
set -euo pipefail
DIR="$HOME/Library/Application Support/Cookbook/backups"
mkdir -p "$DIR"
/opt/homebrew/bin/pg_dump -Fc -d cookbook -f "$DIR/cookbook-$(date +%Y%m%d-%H%M).dump"
find "$DIR" -name 'cookbook-*.dump' -mtime +14 -delete
echo "backup ok: $(ls -1 "$DIR" | tail -1)"
