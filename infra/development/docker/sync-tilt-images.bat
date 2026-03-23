@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-tilt-images.ps1" %*

endlocal
