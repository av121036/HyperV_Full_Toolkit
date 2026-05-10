@echo off
chcp 65001 >nul

:: 將輸出檔案鎖定在 bat 檔所在的當前目錄
set "OUTPUT_FILE=%~dp0my_ip.txt"

echo 正在擷取網路卡名稱與對應的 IP 位址...

:: 建立 txt 檔並寫入標頭 (已經補上遺漏的 >> 符號)
echo ======================================================== > "%OUTPUT_FILE%"
echo   本機網路卡與 IPv4 對照表 (排除本機迴環位址) >> "%OUTPUT_FILE%"
echo ======================================================== >> "%OUTPUT_FILE%"
echo. >> "%OUTPUT_FILE%"

:: 呼叫 PowerShell 抓取網卡與 IP (確保這是一整行，沒有斷行)
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch 'Loopback|Pseudo' } | Select-Object @{Name='網路卡名稱 (Interface)';Expression={$_.InterfaceAlias}}, @{Name='IPv4 位址 (IP Address)';Expression={$_.IPAddress}} | Format-Table -AutoSize" >> "%OUTPUT_FILE%"

echo.
echo [成功] 已列出所有網卡名稱與 IP！
echo 檔案位置：%OUTPUT_FILE%
echo ========================================================
pause