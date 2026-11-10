@echo off
echo ============================================
echo   Zepto Tracker - Chrome Launcher
echo ============================================
echo.
echo Chrome ko remote debugging port ke saath start kar raha hoon...
echo Zepto mein pehle se login hona chahiye!
echo.

:: Kill existing Chrome (optional — remove if you want to keep other Chrome windows)
:: taskkill /f /im chrome.exe 2>nul

:: Launch Chrome with remote debugging port
start "" "C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9222 --restore-last-session

echo.
echo Chrome started with remote debugging on port 9222!
echo Ab backend server start karo: python -m uvicorn app.main:app --host 0.0.0.0 --port 8765
echo.
pause
