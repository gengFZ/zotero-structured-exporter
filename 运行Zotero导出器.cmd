@echo off
chcp 65001 >nul
setlocal
set "EXPORT_SCRIPT=%~dp0Export-ZoteroCollection.ps1"
if not exist "%EXPORT_SCRIPT%" (
    echo ERROR: Export-ZoteroCollection.ps1 was not found.
    echo Keep the CMD and PS1 files in the same folder.
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%EXPORT_SCRIPT%"
set "EXPORT_EXIT=%ERRORLEVEL%"
if errorlevel 1 (
    echo Export failed. See the error message above.
)
echo.
pause
endlocal & exit /b %EXPORT_EXIT%

