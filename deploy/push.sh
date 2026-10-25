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
  systemctl is-active cookbook-api"
# Startup runs pending migrations first, so the API can take a while to answer.
for _ in $(seq 1 30); do
  curl -fsS "https://$HOST/healthz" 2>/dev/null && echo "  <- https://$HOST is up" && exit 0
  sleep 1
done
echo "https://$HOST/healthz didn't answer within 30 s; check: journalctl -u cookbook-api" >&2
exit 1
