@echo off
REM ============================================================
REM  VM_Create_v1.0.bat - Hyper-V VM Auto-Create Launcher
REM  Run on the HOST as Administrator.
REM  Scans a folder for .vhdx, lists them, and builds a VM
REM  with sensible defaults (Gen2 / 6GB static / 4 vCPU /
REM  first External switch, fallback Default Switch).
REM ============================================================
title VM Create v1.0 - Hyper-V Auto Builder

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0VM_Create_v1.0.ps1"
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
