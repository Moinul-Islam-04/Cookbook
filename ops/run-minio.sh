#!/bin/bash
# Photo storage on 127.0.0.1:9000 only (not Homebrew's service, which listens on all
# interfaces with default credentials). Credentials come from backend/.env.
set -euo pipefail
cd "$(dirname "$0")/../backend"
set -a; . ./.env; set +a
DATA="$HOME/Library/Application Support/Cookbook/minio"
mkdir -p "$DATA"
MINIO_ROOT_USER="$COOKBOOK_S3_ACCESS_KEY" MINIO_ROOT_PASSWORD="$COOKBOOK_S3_SECRET_KEY" MINIO_BROWSER=off \
  exec /opt/homebrew/bin/minio server --address 127.0.0.1:9000 --quiet "$DATA"
