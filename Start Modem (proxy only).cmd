@echo off
rem Points the Windows proxy setting at the iPhone instead of routing everything.
rem No administrator rights needed. Browsers and most apps follow it; games and
rem some other programs do not. Press Ctrl+C in this window to stop; the old
rem proxy setting is put back automatically.
setlocal
cd /d "%~dp0windows"
if exist ModemBridge.exe goto run
echo Running first-time setup...
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\setup.ps1"
if errorlevel 1 goto failed

:run
ModemBridge.exe --mode proxy
if errorlevel 1 pause
exit /b

:failed
echo Setup failed. See the messages above.
pause
exit /b 1
