@echo off
REM ============================================================
REM  VM_DiagSvc_v1.0.bat - VirtualRender KMD service deep check
REM  Run this INSIDE the VM as Administrator.
REM
REM  Checks whether the partition kernel-mode driver service
REM  (VirtualRender, defined by vrd.inf) is actually running,
REM  where vrd.sys lives, and whether it exists at all.
REM
REM  The result tells us whether the Win10 + Blackwell GPU-PV
REM  failure is at the file level, service level, or protocol level.
REM ============================================================
title VM DiagSvc v1.0 - VirtualRender KMD service deep check

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0VM_DiagSvc_v1.0.ps1"
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
