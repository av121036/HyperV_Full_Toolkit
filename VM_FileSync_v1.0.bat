@echo off
rem =====================================================================
rem  VM FileSync v1.0 - launcher
rem  ASCII ONLY on purpose: cmd.exe parses .bat bytes using the console
rem  codepage (cp950 here), so CJK text inside a .bat corrupts parsing and
rem  can swallow adjacent lines. Chinese notes live in the README .txt.
rem  Also: never expand %~dp0 inside an ( ) block - a folder name that
rem  contains ')' terminates the block early and the script dies.
rem =====================================================================
setlocal
title VM FileSync v1.0

net session >nul 2>&1
if %errorLevel% neq 0 goto :elevate

set "PS1=%~dp0VM_FileSync_GUI_v1.0.ps1"
if not exist "%PS1%" goto :nogui

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%PS1%"
goto :eof

:elevate
echo Requesting administrator privileges...
powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
goto :eof

:nogui
echo.
echo   GUI script not found:
echo   %PS1%
echo.
echo   Falling back to the command line engine. Examples:
echo     VM_FileSync_v1.0.ps1 -ListOnly
echo     VM_FileSync_v1.0.ps1 -VMName 4 -Dest C:\VMShare -AddExclusion -DryRun
echo.
pause
goto :eof
