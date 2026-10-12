@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app-tools.ps1" -Action autostart-on
pause
