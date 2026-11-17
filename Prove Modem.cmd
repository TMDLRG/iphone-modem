@echo off
rem Shows with byte counters that traffic goes through Modem, not Personal Hotspot.
rem Run while Modem is connected. Downloads 25 MB of test data over cellular.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\prove-modem.ps1"
echo.
pause
