@echo off
echo ============================================
echo   Zepto Tracker - Full Startup
echo ============================================
echo.
echo Step 1: Chrome start ho raha hai (remote debugging ke saath)...
start "" "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222 --restore-last-session
timeout /t 3 /nobreak >nul
echo Chrome started!
echo.
echo Step 2: Backend server start ho raha hai...
echo.
cd /d "%~dp0"
python -m uvicorn app.main:app --host 0.0.0.0 --port 8765
