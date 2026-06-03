@echo off
setlocal
cd /d "%~dp0"

where python >nul 2>nul
if %ERRORLEVEL%==0 (
  python "%~dp0start.py" %*
) else (
  py -3 "%~dp0start.py" %*
)
