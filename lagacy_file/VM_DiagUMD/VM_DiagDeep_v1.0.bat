@echo off
REM ============================================================
REM  VM_DiagDeep_v1.0.bat - Deep diagnostics for GPU-PV D3D dead
REM  Run this INSIDE the VM as Administrator.
REM
REM  Captures HVCI/VBS state, NVIDIA UMD/KMD versions, PnP problem
REM  codes, 24h Display event log, dxdiag display section.
REM
REM  Output is long - run, screenshot or copy all output, paste back.
REM ============================================================
title VM DiagDeep v1.0 - Deep GPU-PV diagnostics

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0VM_DiagDeep_v1.0.ps1"
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
