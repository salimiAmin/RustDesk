@echo off
set "SCRIPT=%~dp0Install-Sepidyar-RustDesk.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
