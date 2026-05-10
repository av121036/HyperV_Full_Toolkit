@echo off
REM ============================================================
REM  VM_Master_v1.0.bat - VM All-in-One Setup Launcher
REM  Run this INSIDE the VM as Administrator.
REM  Combines: VM_NVFix (OpenGL/D3D ICD patch)
REM          + VM_Camo  (BIOS / GUID / hostname camouflage)
REM  Single run, single reboot.
REM ============================================================
title VM Master v1.0 - All-in-One (NVFix + Camo)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0VM_Master_v1.0.ps1"
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
