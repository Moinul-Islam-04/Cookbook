#!/bin/bash
# Nightly pg_dump (custom format; restore with pg_restore), uploaded to the backup bucket.
# The bucket's lifecycle rule deletes copies after 14 days; 3 stay on the server's disk.
set -euo pipefail
DIR=/var/backups/cookbook
FILE="$DIR/cookbook-$(date -u +%Y%m%d-%H%M).dump"
pg_dump -Fc -d cookbook -f "$FILE"
/opt/cookbook/backend/.venv/bin/python - "$FILE" <<'PY'
import os, sys, boto3
path = sys.argv[1]
boto3.client(
    "s3",
    region_name=os.environ["COOKBOOK_S3_REGION"],
    aws_access_key_id=os.environ["COOKBOOK_S3_ACCESS_KEY"],
    aws_secret_access_key=os.environ["COOKBOOK_S3_SECRET_KEY"],
).upload_file(path, os.environ["COOKBOOK_BACKUP_BUCKET"], "db/" + os.path.basename(path))
PY
ls -1t "$DIR"/cookbook-*.dump | tail -n +4 | xargs -r rm --
echo "backup ok: $(basename "$FILE")"
