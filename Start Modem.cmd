@echo off
rem Routes this whole PC through the iPhone's cellular data over USB.
rem Asks for administrator rights (needed to create the network adapter).
setlocal
cd /d "%~dp0windows"
if not exist ModemBridge.exe goto setup
if not exist tools\tun2socks.exe goto setup
if not exist tools\wintun.dll goto setup
goto run

:setup
echo Running first-time setup...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\setup.ps1"
if errorlevel 1 goto failed

:run
ModemBridge.exe --mode full
if errorlevel 1 pause
exit /b

:failed
echo Setup failed. See the messages above.
pause
exit /b 1
