@echo off
REM ============================================================
REM  Host_Master_v1.7.bat - GPU-PV Passthrough + Driver Copy to VHDX
REM  v1.7: Tuned MMIO 1G/8G + GPU quota 8% (multi-VM friendly)
REM  v1.5: 5d auto-detects NC / NCSOFT roots (Lineage / Purple / Aion / Blade / Throne / BnS)
REM  Pure ASCII launcher - UI rendered by PowerShell
REM ============================================================
title Host Master v1.7 - GPU Passthrough + Driver Copy (Multi-VM)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0Host_Master_v1.7.ps1"
if not exist "%PS1%" (
    echo [X] Missing file: %PS1%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
set "RC=%errorlevel%"

echo.
if %RC% neq 0 (
    echo [!] Script ended with exit code %RC%
)
pause
exit /b %RC%
