#!/bin/bash
# The API on 127.0.0.1:8000. Reached from the iPhone via `tailscale serve` (HTTPS), never
# directly from the network. Settings come from backend/.env.
set -euo pipefail
cd "$(dirname "$0")/../backend"
.venv/bin/alembic upgrade head
exec .venv/bin/uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
