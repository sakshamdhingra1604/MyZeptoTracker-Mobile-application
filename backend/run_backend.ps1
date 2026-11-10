# ==========================================
# myzeptotracker Backend Auto-Runner
# ==========================================
Set-Location -Path $PSScriptRoot
$host.ui.RawUI.WindowTitle = "myzeptotracker Backend"
Clear-Host
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host " Starting myzeptotracker Backend on port 8765..." -ForegroundColor Green
Write-Host " Backend URL: http://localhost:8765" -ForegroundColor Yellow
Write-Host "====================================================" -ForegroundColor Cyan
Write-Host ""

$pythonExe = "C:\Users\HP\AppData\Local\Programs\Python\Python314\python.exe"
if (-not (Test-Path $pythonExe)) {
    $pythonExe = "python"
}

& $pythonExe -m uvicorn app.main:app --host 0.0.0.0 --port 8765
