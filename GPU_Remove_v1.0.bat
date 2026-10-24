@echo off
REM ============================================================
REM  GPU_Remove_v1.0.bat - Remove GPU-PV partition from a VM
REM  Reverses Host_Master v1.7: removes GPU partition adapter,
REM  restores default MMIO/cache, optionally cleans NVIDIA
REM  driver files copied into the VHDX.
REM  Pure ASCII launcher - UI rendered by PowerShell
REM ============================================================
title GPU Remove v1.0 - Remove GPU-PV Passthrough

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0GPU_Remove_v1.0.ps1"
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
