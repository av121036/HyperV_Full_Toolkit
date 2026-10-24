@echo off
REM ============================================================
REM  Game_Share_GUI_v1.0.bat - Game Copy + SMB Share GUI
REM  Tab 1: copy game folders (NCSOFT + Gamania maplestory_classic)
REM         into a VM's VHDX (Host_Master v1.7 section 5d logic)
REM  Tab 2: one-click SMB share setup (Host_Share v1.5 logic)
REM  Pure ASCII launcher - UI rendered by PowerShell WinForms
REM ============================================================
title Game + Share GUI v1.0

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0Game_Share_GUI_v1.0.ps1"
if not exist "%PS1%" (
    echo [X] Missing file: %PS1%
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS1%"
exit /b %errorlevel%
