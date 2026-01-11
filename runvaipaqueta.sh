#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$PROJECT_ROOT/vai_paqueta_backend"
VENV_BIN="$BACKEND_DIR/.venv/bin"
SERVICE_BACKEND="vai-paqueta-backend.service"
SERVICE_TUNNEL="cloudflared.service"

usage() {
  cat <<USAGE
Uso: $0 [start|restart|status]

start/restart: roda migrate, collectstatic e inicia/reinicia os serviços.
status: exibe status dos serviços do backend e tunnel.
USAGE
}

ensure_venv() {
  if [[ ! -x "$VENV_BIN/python" ]]; then
    echo "Python do venv não encontrado em $VENV_BIN/python" >&2
    exit 1
  fi
}

migrate_and_collect() {
  cd "$BACKEND_DIR"
  "$VENV_BIN/python" manage.py migrate --noinput
  "$VENV_BIN/python" manage.py collectstatic --noinput
}

case "${1:-}" in
  start)
    ensure_venv
    migrate_and_collect
    systemctl start "$SERVICE_BACKEND"
    systemctl start "$SERVICE_TUNNEL"
    ;;
  restart)
    ensure_venv
    migrate_and_collect
    systemctl restart "$SERVICE_BACKEND"
    systemctl restart "$SERVICE_TUNNEL"
    ;;
  status)
    systemctl status --no-pager "$SERVICE_BACKEND" "$SERVICE_TUNNEL"
    exit 0
    ;;
  *)
    usage
    exit 1
    ;;
 esac

systemctl status --no-pager "$SERVICE_BACKEND"
