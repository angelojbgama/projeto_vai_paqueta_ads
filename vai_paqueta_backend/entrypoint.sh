#!/usr/bin/env sh
set -e

if [ -n "${DJANGO_DB_PATH:-}" ]; then
  mkdir -p "$(dirname "$DJANGO_DB_PATH")"
fi

python manage.py migrate --noinput
python manage.py collectstatic --noinput

exec "$@"
