@echo off
setlocal
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Invoke-MuteCueHardwareAcceptance.ps1"
echo.
pause
endlocal
