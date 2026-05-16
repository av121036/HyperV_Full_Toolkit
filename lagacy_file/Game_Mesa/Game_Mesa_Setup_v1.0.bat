@echo off
REM ============================================================
REM  Game_Mesa_Setup_v1.0.bat - Deploy Mesa llvmpipe to a game
REM
REM  Use this when GPU-PV is broken (D3D/Vulkan/OpenGL all dead
REM  in the VM because Win10 vrd.inf cannot handshake with
REM  Blackwell partition) and you want to fall back to CPU
REM  software rendering for older OpenGL games (Lineage Classic,
REM  Minecraft, etc.).
REM
REM  Requires:
REM    1. pal1000 mesa-dist-win extracted to C:\Mesa (or asks)
REM       Download: https://github.com/pal1000/mesa-dist-win/releases
REM       Take: mesa3d-XX.X.X-release-msvc.7z, extract with 7-Zip
REM    2. Run as Administrator (writing to Program Files (x86))
REM ============================================================
title Game Mesa Setup v1.0 - llvmpipe software OpenGL deploy

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Administrator privileges required.
    echo     Right-click this file and select "Run as administrator".
    echo.
    pause
    exit /b 1
)

set "PS1=%~dp0Game_Mesa_Setup_v1.0.ps1"
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
