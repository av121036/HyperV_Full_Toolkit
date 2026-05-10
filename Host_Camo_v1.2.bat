@echo off
REM ============================================================
REM  Host_Camo_v1.2.bat - Hyper-V Host side VM camouflage launcher
REM  v1.2: 支援批量選擇 (逗號 / 區間 / all)
REM ============================================================
title Host Camo v1.2 - Hyper-V VM Camouflage (Batch)

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0Host_Camo_v1.2.ps1"
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
