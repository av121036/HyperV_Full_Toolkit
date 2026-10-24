@echo off
REM ============================================================
REM  Host_Master_DriverOnly_v1.1.bat
REM  GPU-PV Passthrough + Driver Copy ONLY (no game copy)
REM  Based on DriverOnly v1.0 (= Host_Master_v1.7 without game copy)
REM
REM  v1.1: copies only the display driver package whose version
REM        matches the host's active driver (v1.0 flattened every
REM        package it found, last one won -> stale driver in VM);
REM        version self-check inside the VHDX; adapter count check;
REM        optional wipe of old NVIDIA driver files before copying.
REM        Extra arguments are forwarded to the .ps1:
REM          -Preview        scan host + list VMs, change nothing
REM          -VMName <name>  skip the VM menu (exact name)
REM          -Yes            answer Y to every prompt
REM          -CleanOld       wipe old NVIDIA driver files in the VHDX
REM                          before copying (clean reinstall), no prompt
REM          -NoCleanOld     skip the wipe, no prompt
REM                          (neither given: the script asks once)
REM  Pure ASCII launcher - UI rendered by PowerShell
REM ============================================================
title Host Master DriverOnly v1.1 - GPU Passthrough + Driver Copy (No Games)

net session >nul 2>&1
if %errorlevel% neq 0 goto :noadmin

set "PS1=%~dp0Host_Master_DriverOnly_v1.1.ps1"
if not exist "%PS1%" goto :missing

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
set "RC=%errorlevel%"

echo.
if %RC% neq 0 echo [!] Script ended with exit code %RC%
pause
exit /b %RC%

:noadmin
echo.
echo [X] Administrator privileges required.
echo     Right-click this file and select "Run as administrator".
echo.
pause
exit /b 1

:missing
echo [X] Missing file: %PS1%
pause
exit /b 1
