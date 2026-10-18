#!/bin/bash
# One-time setup of a fresh Ubuntu 24.04 server, run as root (deploy/push.sh does this).
# Idempotent: safe to run again. Needs /etc/cookbook/env to exist first.
set -euo pipefail
HOST="$1"   # e.g. 3-14-15-92.sslip.io

# 1 GB of RAM is tight for PostgreSQL + the API + photo processing; add 1 GB of swap.
if [ ! -f /swapfile ]; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q postgresql python3-venv python3-dev build-essential libpq-dev caddy unattended-upgrades

id cookbook >/dev/null 2>&1 || useradd --system --home /opt/cookbook --shell /usr/sbin/nologin cookbook
mkdir -p /opt/cookbook /var/backups/cookbook
chown cookbook:cookbook /var/backups/cookbook
chmod 640 /etc/cookbook/env && chown root:cookbook /etc/cookbook/env

# PostgreSQL listens on localhost only (Ubuntu's default); the cookbook OS user connects
# over the Unix socket with peer authentication, so there's no database password.
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='cookbook'" | grep -q 1 \
  || sudo -u postgres createuser cookbook
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='cookbook'" | grep -q 1 \
  || sudo -u postgres createdb -O cookbook cookbook

echo "COOKBOOK_HOST=$HOST" > /etc/default/caddy
mkdir -p /etc/systemd/system/caddy.service.d
printf '[Service]\nEnvironmentFile=/etc/default/caddy\n' > /etc/systemd/system/caddy.service.d/env.conf
install -m 644 /opt/cookbook/deploy/Caddyfile /etc/caddy/Caddyfile
install -m 644 /opt/cookbook/deploy/cookbook-*.service /opt/cookbook/deploy/cookbook-*.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now cookbook-cleanup.timer cookbook-backup.timer
systemctl enable cookbook-api caddy
systemctl restart caddy
echo "setup ok"
