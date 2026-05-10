@echo off

chcp 65001 >nul

title Win10 專用 - Hyper-V 多開顯卡直通工具

color 0B



:: 1. 檢查系統管理員權限

>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"

if '%errorlevel%' NEQ '0' (

    echo ===================================================

    echo [警告] 權限不足！請右鍵「以系統管理員身分執行」!

    echo ===================================================

    pause

    exit /b

)



echo ===================================================

echo   Windows 10 專屬 - 雙開/多開掛載工具 (1G/8G 通道)

echo ===================================================

echo.



set /p vmName="👉 請輸入你要掛載外顯的「虛擬機名稱」: "



if "%vmName%"=="" exit /b



echo.

echo 🔍 正在執行 Windows 10 底層掛載手術...

echo.

echo 🔍 正在設定虛擬機 MMIO 並掛載顯卡...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$vm='%vmName%'; Remove-VMGpuPartitionAdapter -VMName $vm -ErrorAction SilentlyContinue; Set-VM -Name $vm -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1Gb -HighMemoryMappedIoSpace 32Gb; Add-VMGpuPartitionAdapter -VMName $vm; Write-Host '✅ 手術成功！已成功將實體顯示卡掛載給虛擬機！' -ForegroundColor Green"


echo.
echo ===================================================
echo 🎉 腳本執行完畢！顯卡已成功配對！
echo ===================================================
pause