@echo off
REM ============================================================
REM  Host_Master_DriverOnly_v2.bat
REM  GPU-PV Passthrough + Driver Copy ONLY (no game copy)
REM  Vendor-agnostic: auto-detects NVIDIA or AMD partitionable GPU
REM  Based on DriverOnly v1.1 (same VM setup / VHDX mount / exit codes)
REM
REM  v2: detects GPU vendor from Msvm_PartitionableGpu (VEN_10DE =
REM      NVIDIA, VEN_1002 = AMD) instead of assuming NVIDIA. Package
REM      selection, flattening (with per-file PE architecture routing),
REM      self-check and -CleanOld are all vendor-aware. NVIDIA behavior
REM      is unchanged from v1.1; AMD is newly supported.
REM      Extra arguments are forwarded to the .ps1:
REM        -Preview        scan host + list VMs, change nothing
REM        -VMName <name>  skip the VM menu (exact name)
REM        -Yes            answer Y to every prompt
REM        -CleanOld       wipe old same-vendor driver files in the VHDX
REM                        before copying (clean reinstall), no prompt
REM        -NoCleanOld     skip the wipe, no prompt
REM                        (neither given: the script asks once)
REM  Pure ASCII launcher - UI rendered by PowerShell
REM ============================================================
title Host Master DriverOnly v2 - GPU Passthrough + Driver Copy (NVIDIA/AMD, No Games)

net session >nul 2>&1
if %errorlevel% neq 0 goto :noadmin

set "PS1=%~dp0Host_Master_DriverOnly_v2.ps1"
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
