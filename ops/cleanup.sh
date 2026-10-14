#!/bin/bash
# Expired drafts, old idempotency keys, orphaned photo objects.
set -euo pipefail
cd "$(dirname "$0")/../backend"
exec .venv/bin/python -m app.cleanup
