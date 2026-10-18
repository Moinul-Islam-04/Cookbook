#!/bin/bash
# Copy the backend and deploy files to the server, install dependencies, restart the API.
#   deploy/push.sh                  # deploy the current working tree
#   deploy/push.sh --setup          # first time: also run setup-server.sh
# Needs deploy/server.conf (SERVER_IP, HOST, SSH_KEY) and, for --setup, deploy/server.env
# (the server's secrets; never committed).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/server.conf"
SSH=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "ubuntu@$SERVER_IP")

if [ "${1:-}" = "--setup" ]; then
  "${SSH[@]}" "sudo mkdir -p /etc/cookbook && sudo tee /etc/cookbook/env >/dev/null" < "$HERE/server.env"
fi
"${SSH[@]}" "sudo mkdir -p /opt/cookbook && sudo chown -R ubuntu /opt/cookbook"
rsync -az --delete -e "ssh -i $SSH_KEY" \
  --exclude .venv --exclude .env --exclude __pycache__ --exclude .pytest_cache --exclude eval \
  "$HERE/../backend" "$HERE" "ubuntu@$SERVER_IP:/opt/cookbook/" \
  --exclude server.env --exclude server.conf
if [ "${1:-}" = "--setup" ]; then
  "${SSH[@]}" "sudo bash /opt/cookbook/deploy/setup-server.sh $HOST"
fi
"${SSH[@]}" "set -e
  cd /opt/cookbook/backend
  [ -d .venv ] || python3 -m venv .venv
  .venv/bin/pip install -q -r requirements.txt
  sudo chown -R cookbook:cookbook /opt/cookbook
  sudo systemctl restart cookbook-api
  sleep 3; systemctl is-active cookbook-api"
curl -fsS "https://$HOST/healthz" && echo "  <- https://$HOST is up"
