@echo off
rem remove desktop / start menu shortcuts and the autostart entry
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0app-tools.ps1" -Action remove-shortcuts
pause
