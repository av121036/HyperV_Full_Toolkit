@echo off
REM ============================================================
REM  Open_AdvancedSharing.bat
REM  Opens: Network and Sharing Center -> Advanced sharing settings
REM ============================================================
title Advanced Sharing Settings
start "" control.exe /name Microsoft.NetworkAndSharingCenter /page Advanced
exit /b 0
