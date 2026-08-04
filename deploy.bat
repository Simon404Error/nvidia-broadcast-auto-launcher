@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Deploy.ps1"
exit /b %ERRORLEVEL%
