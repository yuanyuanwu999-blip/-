@echo off
set "APPDIR=%~dp0"
if not exist "%APPDIR%runtime\ffmpeg-full\bin\ffmpeg.exe" goto NEED_SETUP
if not exist "%APPDIR%runtime\edge-tts\Scripts\edge-tts.exe" goto NEED_SETUP
if not exist "%APPDIR%制作模板\node_modules\@remotion\cli\remotion-cli.js" goto NEED_SETUP
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APPDIR%视频批量制作助手.ps1"
exit /b

:NEED_SETUP
echo This computer has not installed the video assistant components.
echo Starting the one-click installer...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%APPDIR%安装到新电脑.ps1"
pause
