@echo off
cd /d "%~dp0"
title myzeptotracker Backend
cls
echo ====================================================
echo Starting myzeptotracker Backend on port 8765...
echo ====================================================
echo.
echo IP: 0.0.0.0:8765
echo.
C:\Users\HP\AppData\Local\Programs\Python\Python314\python.exe -m uvicorn app.main:app --host 0.0.0.0 --port 8765
if %ERRORLEVEL% NEQ 0 (
    python -m uvicorn app.main:app --host 0.0.0.0 --port 8765
)
pause
