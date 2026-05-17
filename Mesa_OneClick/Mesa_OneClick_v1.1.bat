@echo off
REM ============================================================
REM  Mesa_OneClick_v1.1.bat - GUI launcher
REM
REM  v1.1 (vs v1.0):
REM    + Auto-add C:\Mesa + TempDir to Defender ExclusionPath
REM    + Try to disable real-time protection during install
REM    + Auto-restore RTP when done
REM    + Tolerates Tamper Protection (falls back to exclusions only)
REM
REM  Workflow (all GUI-driven):
REM    0. (NEW) Prep Windows Defender (exclusion + RTP off)
REM    1. Auto-download 7zr.exe (if missing)
REM    2. Auto-download pal1000 Mesa msvc latest (~30-80 MB)
REM    3. Extract to C:\Mesa
REM    4. Auto-detect NC/NCSOFT game folders
REM    5. Deploy Mesa DLLs + create .exe.local in each game
REM    6. Set system-wide Mesa env vars (Machine level)
REM    7. Restore Defender RTP
REM    8. Optional: restart explorer.exe to apply env vars
REM
REM  One-click usage: open as Admin, click "OneClick" button.
REM ============================================================
title Mesa OneClick v1.1 - GUI installer for software OpenGL

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0Mesa_OneClick_v1.1.ps1"
if not exist "%PS1%" (
    echo [X] Missing file: %PS1%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"
exit /b 0
