@echo off
REM ============================================================
REM  VM_DiagUMD_v1.0.bat - GPU-PV UMD binding diagnostics launcher
REM  Run this INSIDE the VM as Administrator.
REM
REM  Dumps the registry binding of the current OK NVIDIA partition
REM  device so you can see whether UserModeDriverName/OpenGLDriverName
REM  point to the current real driver folder hash, or a stale one
REM  left over from a previous NVIDIA driver version.
REM ============================================================
title VM DiagUMD v1.0 - GPU-PV UMD binding diagnostics

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0VM_DiagUMD_v1.0.ps1"
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
