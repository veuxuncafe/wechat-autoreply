@echo off
rem re-show the taskbar window if Windows hid it
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tray-show.ps1"
