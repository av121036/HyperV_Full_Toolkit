@echo off
REM ============================================================
REM  VM_NVFix_v1.0.bat - GPU-PV NVIDIA OpenGL/D3D ICD Fix
REM  Run this INSIDE the VM as Administrator.
REM  Fixes "no driver" / Microsoft Basic Render Driver after
REM  GPU-PV passthrough by registering NVIDIA's OpenGL ICD and
REM  D3D user-mode driver against the vrd.inf class subkeys.
REM ============================================================
title VM NVFix v1.0 - NVIDIA OpenGL/D3D ICD Patch

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0VM_NVFix_v1.0.ps1"
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
