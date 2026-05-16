@echo off
REM ============================================================
REM  VM_FixUMD_v1.0.bat - GPU-PV D3D UMD path fix launcher
REM  Run this INSIDE the VM as Administrator.
REM
REM  Writes the missing D3D10/11/12 UMD registry entries so that
REM  Windows D3D selects nvwgf2umx.dll (NVIDIA) instead of falling
REM  back to Microsoft Basic Render Driver.
REM
REM  Run AFTER:
REM    - Host_Master has copied NVIDIA driver into the VM
REM    - VM_DiagUMD has confirmed the missing D3D UMD entries
REM ============================================================
title VM FixUMD v1.0 - GPU-PV D3D UMD path fix

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0VM_FixUMD_v1.0.ps1"
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
