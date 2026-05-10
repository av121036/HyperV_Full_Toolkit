@echo off
REM ============================================================
REM  VM_GPUWakeup_v1.0.bat - GPU Wakeup Installer Launcher
REM  Run this INSIDE the VM as Administrator.
REM
REM  Installs C:\GPU_Wakeup.ps1 and registers an AtStartup
REM  scheduled task that wakes up NVIDIA GPU partition so
REM  opengl32.dll caches the NVIDIA ICD instead of GDI Generic.
REM ============================================================
title VM GPU Wakeup v1.0 - GPU partition warmup installer

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0VM_GPUWakeup_v1.0.ps1"
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
