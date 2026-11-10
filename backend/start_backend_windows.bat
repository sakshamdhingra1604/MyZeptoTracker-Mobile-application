@echo off
setlocal
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  echo Creating Python virtual environment...
  py -3 -m venv .venv
  if errorlevel 1 python -m venv .venv
)
if not exist ".env" (
  copy ".env.example" ".env" >nul
  echo Created backend\.env. Edit API_KEY before using the phone app.
)
call ".venv\Scripts\activate.bat"
python -m pip install --upgrade pip
pip install -r requirements.txt
if errorlevel 1 pause & exit /b 1
echo Starting myzeptotracker API on port 8765...
python -m uvicorn app.main:app --host 0.0.0.0 --port 8765
pause
