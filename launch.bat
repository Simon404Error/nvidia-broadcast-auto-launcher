@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-NvidiaBroadcast.ps1" %*
exit /b %ERRORLEVEL%
