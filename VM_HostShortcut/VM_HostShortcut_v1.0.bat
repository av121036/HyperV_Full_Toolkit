@echo off
REM ============================================================
REM  VM_HostShortcut_v1.0.bat - Auto-detect host + desktop link
REM  Run this INSIDE the VM as Administrator.
REM
REM  Replaces the manual "open file explorer, type \\Host, drag
REM  to desktop" workflow. Uses Hyper-V Integration Services KVP
REM  to read the host name dynamically (works even if host IP
REM  changes), applies the SMB/UAC registry fixes, builds a
REM  desktop shortcut to \\<HostName>\share_folder.
REM ============================================================
title VM HostShortcut v1.0 - auto-detect host share

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0VM_HostShortcut_v1.0.ps1"
if not exist "%PS1%" (
    echo [X] Missing file: %PS1%
    pause
    exit /b 1
)

REM Pass -MapDrive to also map Z: (or pass nothing for shortcut only)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -MapDrive
set "RC=%errorlevel%"

echo.
if %RC% neq 0 (
    echo [!] Script ended with exit code %RC%
)
pause
exit /b %RC%
