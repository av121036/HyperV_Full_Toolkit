@echo off
REM ============================================================
REM  Show_IP.bat - Display Host IP / Network Configuration
REM  Pure ASCII launcher - shows IPCONFIG /ALL with summary
REM ============================================================
title Show IP - Host Network Information

echo ============================================================
echo               Host Network Information
echo ============================================================
echo.
echo  Computer Name : %COMPUTERNAME%
echo  User Name     : %USERNAME%
echo  Date / Time   : %DATE% %TIME%
echo.
echo ============================================================
echo                  IPCONFIG /ALL  (Full)
echo ============================================================
echo.
ipconfig /all
echo.
echo ============================================================
echo                       IP Summary
echo ============================================================
echo.

echo [ IPv4 Address ]
ipconfig | findstr /R /C:"IPv4"
echo.

echo [ Default Gateway ]
ipconfig | findstr /R /C:"Default Gateway" /C:"Gateway"
echo.

echo [ Subnet Mask ]
ipconfig | findstr /R /C:"Subnet Mask"
echo.

echo [ DNS Servers ]
ipconfig /all | findstr /R /C:"DNS Servers"
echo.

echo ============================================================
echo  Done.  Press any key to exit . . .
echo ============================================================
pause
exit /b 0
