#!/bin/bash
# One-time move of this Mac's cookbook to the server: the PostgreSQL database and the
# MinIO photos. REPLACES the server's database (pg_restore --clean); the Mac's copy is left
# as it is. Run from the repo root:  deploy/migrate-from-mac.sh
# Needs deploy/server.conf, the cookbook AWS profile, and MinIO credentials in backend/.env.
set -euo pipefail
# The AWS CLI installer puts `aws` here; shells started before it was installed lack it.
export PATH="$HOME/.local/bin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/server.conf"
PHOTOS_BUCKET=cookbook-photos-220133863661
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== On the Mac"
psql -d cookbook -Atc "SELECT count(*) || ' recipes, ' || (SELECT count(*) FROM recipe_images) || ' photos' FROM recipes"
pg_dump -Fc -d cookbook -f "$WORK/cookbook.dump"
eval "$(grep -E '^COOKBOOK_S3_(ACCESS_KEY|SECRET_KEY|BUCKET|ENDPOINT_URL)=' "$HERE/../backend/.env" | sed 's/^/export /')"
env -u AWS_PROFILE AWS_ACCESS_KEY_ID="$COOKBOOK_S3_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$COOKBOOK_S3_SECRET_KEY" \
  aws s3 sync "s3://${COOKBOOK_S3_BUCKET:-cookbook-images}" "$WORK/photos" \
  --endpoint-url "${COOKBOOK_S3_ENDPOINT_URL:-http://127.0.0.1:9000}" --region us-east-1 --only-show-errors
echo "downloaded $(find "$WORK/photos" -type f | wc -l | tr -d ' ') photo files from MinIO"

echo "== Photos to S3"
AWS_PROFILE=cookbook aws s3 sync "$WORK/photos" "s3://$PHOTOS_BUCKET" --region us-east-2 --only-show-errors
echo "$PHOTOS_BUCKET now has $(AWS_PROFILE=cookbook aws s3 ls "s3://$PHOTOS_BUCKET" --recursive --region us-east-2 | wc -l | tr -d ' ') files"

echo "== Database to the server (the API is stopped while it restores)"
scp -q -i "$SSH_KEY" "$WORK/cookbook.dump" "ubuntu@$SERVER_IP:/tmp/cookbook.dump"
ssh -i "$SSH_KEY" "ubuntu@$SERVER_IP" 'set -e
  sudo chmod 644 /tmp/cookbook.dump
  sudo systemctl stop cookbook-api
  sudo -u cookbook pg_restore --clean --if-exists --no-owner --no-privileges -d cookbook /tmp/cookbook.dump
  sudo rm /tmp/cookbook.dump
  sudo -u cookbook psql -d cookbook -Atc "SELECT count(*) || '"' recipes, '"' || (SELECT count(*) FROM recipe_images) || '"' photos on the server'"' FROM recipes"
  sudo systemctl start cookbook-api
  sleep 3; echo "API: $(systemctl is-active cookbook-api)"'
curl -fsS "https://$HOST/healthz" >/dev/null && echo "https://$HOST is up"
