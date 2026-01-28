@echo off
setlocal

cd /d "%~dp0"

set PORT=12000

where cloudflared.exe >nul 2>&1
if errorlevel 1 (
  echo [ERRO] cloudflared.exe nao encontrado no PATH.
  echo Baixe em: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
  exit /b 1
)

if not exist ".venv\Scripts\python.exe" (
  echo [ERRO] Ambiente virtual nao encontrado em .venv
  echo Crie a venv e instale os requisitos antes de iniciar.
  exit /b 1
)

start "cloudflared" cloudflared.exe tunnel --url http://localhost:%PORT%

call ".venv\Scripts\activate.bat"

if "%DJANGO_DEBUG%"=="" set "DJANGO_DEBUG=1"
if "%DJANGO_ALLOWED_HOSTS%"=="" set "DJANGO_ALLOWED_HOSTS=localhost,127.0.0.1,.trycloudflare.com"
if "%DJANGO_CSRF_TRUSTED_ORIGINS%"=="" set "DJANGO_CSRF_TRUSTED_ORIGINS=https://*.trycloudflare.com"
if "%DJANGO_USE_REDIS%"=="" set "DJANGO_USE_REDIS=0"

python manage.py migrate --noinput
python manage.py collectstatic --noinput

if exist ".venv\Scripts\daphne.exe" (
  daphne -b 0.0.0.0 -p %PORT% vai_paqueta.asgi:application
) else (
  python manage.py runserver 0.0.0.0:%PORT%
)
