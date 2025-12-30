@echo off
setlocal

for %%I in ("%~dp0.") do set "PROJECT_DIR=%%~fI"
set "BACKEND_DIR=%PROJECT_DIR%\vai_paqueta_backend"
set "PYTHON=%BACKEND_DIR%\.venv\Scripts\python.exe"

if not exist "%PYTHON%" (
  echo [ERRO] Python do venv nao encontrado em: "%PYTHON%"
  echo Verifique se o venv existe em "%BACKEND_DIR%\.venv".
  exit /b 1
)

start "Django" /D "%BACKEND_DIR%" "%PYTHON%" manage.py runserver 127.0.0.1:8000
start "Cloudflared" /D "%PROJECT_DIR%" cloudflared tunnel run vai-paqueta-backend

echo [OK] Servicos iniciados em janelas separadas.
endlocal
