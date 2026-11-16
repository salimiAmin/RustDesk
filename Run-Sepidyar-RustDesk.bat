@echo off
setlocal
chcp 65001 >nul
set "SCRIPT=%~dp0Install-Sepidyar-RustDesk.ps1"

if not exist "%SCRIPT%" (
    echo ERROR: Install-Sepidyar-RustDesk.ps1 was not found next to this BAT file.
    pause
    exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo RustDesk deployment failed. Check the log under:
    echo %ProgramData%\Sepidyar\RustDesk\Install-Sepidyar-RustDesk.log
    pause
    exit /b %RC%
)

endlocal
