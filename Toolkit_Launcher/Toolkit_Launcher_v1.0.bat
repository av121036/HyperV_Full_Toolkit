@echo off
REM ============================================================
REM  Toolkit_Launcher_v1.0.bat - Unified GUI launcher
REM
REM  Wraps all .bat files in HyperV_Full_Toolkit-main\ into a
REM  single GUI workflow:
REM    Tab 1 - Host-side setup    (Windows Features -> Advanced
REM            Sharing -> Host_Master -> Host_Share -> Host_Camo)
REM    Tab 2 - VM-side setup      (VM_Master -> VM_GPUWakeup ->
REM            VM_HostShortcut -> Mesa_OneClick)
REM    Tab 3 - Diagnostics        (Show_IP / Defender / VM_Diag*)
REM
REM  Progress is saved to Toolkit_Launcher_State.json so reopening
REM  the launcher remembers which steps you've already done.
REM ============================================================
title HyperV Toolkit Launcher v1.0

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0Toolkit_Launcher_v1.0.ps1"
if not exist "%PS1%" (
    echo [X] Missing file: %PS1%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"
exit /b 0
