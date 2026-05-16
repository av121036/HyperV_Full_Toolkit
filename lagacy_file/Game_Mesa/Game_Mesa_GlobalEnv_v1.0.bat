@echo off
REM ============================================================
REM  Game_Mesa_GlobalEnv_v1.0.bat - Set Mesa env vars system-wide
REM
REM  Use this AFTER Game_Mesa_Setup_v1.0 has deployed Mesa DLLs
REM  to the game folder. This sets the 5 Mesa env vars at the
REM  Machine (system-wide) level so any process - including
REM  Purple-spawned LC.exe - inherits them.
REM ============================================================
title Game Mesa GlobalEnv v1.0 - System-wide Mesa env vars

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0Game_Mesa_GlobalEnv_v1.0.ps1"
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
