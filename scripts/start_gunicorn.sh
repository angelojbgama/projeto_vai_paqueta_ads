#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$PROJECT_ROOT/vai_paqueta_backend"
VENV_BIN="$BACKEND_DIR/.venv/bin"

if [[ ! -x "$VENV_BIN/python" ]]; then
  echo "[ERRO] Python do venv nao encontrado em: $VENV_BIN/python" >&2
  exit 1
fi

cd "$BACKEND_DIR"
"$VENV_BIN/python" manage.py collectstatic --noinput

exec "$VENV_BIN/gunicorn" vai_paqueta.wsgi:application \
  --bind "${GUNICORN_BIND:-127.0.0.1:8000}" \
  --workers "${GUNICORN_WORKERS:-3}" \
  --timeout "${GUNICORN_TIMEOUT:-120}"
