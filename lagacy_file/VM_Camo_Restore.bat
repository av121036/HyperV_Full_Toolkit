@echo off
REM VM_Camo_Restore.bat - launcher with UAC elevation (ASCII-safe)
setlocal
chcp 65001 >nul 2>&1
cd /d "%~dp0"

if not exist "%~dp0VM_Camo_Restore_v1.0.ps1" (
    echo [X] VM_Camo_Restore_v1.0.ps1 not found in this folder.
    echo     Please keep the .bat and .ps1 in the same folder.
    pause
    exit /b 1
)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [*] Requesting Administrator privileges via UAC...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo ============================================
echo  VM_Camo Restore - Administrator OK
echo ============================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0VM_Camo_Restore_v1.0.ps1"

echo.
echo ============================================
echo  Done. Press any key to close this window.
echo ============================================
pause >nul
