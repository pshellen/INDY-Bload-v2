#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

PORT="${PORT:-8765}"

if lsof -i ":${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Preview server already running on port ${PORT}"
  echo "Preview: http://127.0.0.1:${PORT}/preview.html"
  exit 0
fi

echo "Starting preview server on port ${PORT}..."
exec python3 preview_server.py --port "${PORT}"
