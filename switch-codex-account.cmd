@echo off
setlocal

where pwsh.exe >nul 2>&1
if errorlevel 1 (
    echo [ERROR] pwsh.exe was not found. Install PowerShell 7 and try again.
    exit /b 1
)

pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0switch-codex-account.ps1"
set "switch_exit_code=%ERRORLEVEL%"

if not "%switch_exit_code%"=="0" (
    echo.
    echo Account switching failed. See the error above.
)

exit /b %switch_exit_code%
