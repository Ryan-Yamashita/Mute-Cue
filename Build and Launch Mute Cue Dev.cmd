@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
set "PROJECT=%ROOT%src\MuteCue.Desktop\MuteCue.Desktop.csproj"
set "DEV_DIRECTORY=%ROOT%artifacts\dev"
set "STAGING_DIRECTORY=%ROOT%artifacts\.dev-stage"
set "DEV_EXE=%DEV_DIRECTORY%\MuteCue-Dev.exe"
set "LOCAL_DISCORD_CONFIG=%ROOT%Overlay\MuteCue.DiscordPublicClient.local.json"

title Build and Launch Mute Cue Dev
echo.
echo  Building Mute Cue Dev...
echo.

where dotnet.exe >nul 2>&1
if errorlevel 1 (
    echo  The .NET SDK could not be found. Install the SDK pinned in global.json and try again.
    goto :failed
)

if exist "%DEV_EXE%" (
    start "" /wait "%DEV_EXE%" --shutdown-for-update
    if errorlevel 1 (
        echo  Mute Cue Dev did not close. Exit it from the tray and run this again.
        goto :failed
    )
)

if exist "%STAGING_DIRECTORY%" rmdir /s /q "%STAGING_DIRECTORY%"
mkdir "%STAGING_DIRECTORY%" >nul 2>&1

dotnet publish "%PROJECT%" --configuration Release --runtime win-x64 --self-contained true --output "%STAGING_DIRECTORY%" --nologo -p:MuteCueChannel=Dev
if errorlevel 1 goto :build_failed

if not exist "%STAGING_DIRECTORY%\MuteCue-Dev.exe" (
    echo  The build completed without producing MuteCue-Dev.exe.
    goto :build_failed
)

if exist "%LOCAL_DISCORD_CONFIG%" (
    copy /y "%LOCAL_DISCORD_CONFIG%" "%STAGING_DIRECTORY%\MuteCue.DiscordPublicClient.json" >nul
    if errorlevel 1 goto :build_failed
)

if exist "%STAGING_DIRECTORY%\Runtime" (
    echo  The Dev build unexpectedly contains a legacy Runtime folder.
    goto :build_failed
)

dir /s /b "%STAGING_DIRECTORY%\*.ps1" >nul 2>&1
if not errorlevel 1 (
    echo  The Dev build unexpectedly contains PowerShell files.
    goto :build_failed
)

if not exist "%DEV_DIRECTORY%" mkdir "%DEV_DIRECTORY%" >nul 2>&1
copy /y "%STAGING_DIRECTORY%\MuteCue-Dev.exe" "%DEV_EXE%" >nul
if errorlevel 1 goto :build_failed

if exist "%STAGING_DIRECTORY%\MuteCue.DiscordPublicClient.json" (
    copy /y "%STAGING_DIRECTORY%\MuteCue.DiscordPublicClient.json" "%DEV_DIRECTORY%\MuteCue.DiscordPublicClient.json" >nul
    if errorlevel 1 goto :build_failed
)

rmdir /s /q "%STAGING_DIRECTORY%"

echo.
echo  Mute Cue Dev is ready.
echo  %DEV_EXE%
echo.
if /i "%~1"=="--build-only" exit /b 0
echo  Launching it now...
echo.
start "" "%DEV_EXE%"
exit /b 0

:build_failed
if exist "%STAGING_DIRECTORY%" rmdir /s /q "%STAGING_DIRECTORY%"
echo.
echo  The build failed. Your previous working Dev EXE was left unchanged.

:failed
echo.
pause
exit /b 1
