@echo off
chcp 950 >nul
title Win11 專用 - Hyper-V 多開顯卡直通工具 (1G/4G 通道)
color 0B

:: 1. 檢查系統管理員權限
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo ===================================================
    echo [警告] 權限不足!請對此檔案按右鍵以系統管理員身分執行!
    echo ===================================================
    pause
    exit /b
)

echo ===================================================
echo   Windows 11 專用 - 開啟/多開顯卡直通 (1G/4G 通道)
echo   - LowMemoryMappedIoSpace  = 1 GB
echo   - HighMemoryMappedIoSpace = 4 GB
echo   多開友善設定:讓主機有限的 MMIO 池能切給更多 VM
echo ===================================================
echo.

set /p vmName=">> 請輸入你要重新整理的虛擬機器名稱: "

if "%vmName%"=="" exit /b

echo.
echo [*] 正在執行 Windows 11 多開直通指令...
echo.

:: 2. 呼叫 PowerShell 執行 Win11 核心指令 (移除舊卡 -^> 設定 1G/4G 通道 -^> 重新掛卡)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$vm='%vmName%'; Remove-VMGpuPartitionAdapter -VMName $vm -ErrorAction SilentlyContinue; Set-VM -Name $vm -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1Gb -HighMemoryMappedIoSpace 4Gb; Add-VMGpuPartitionAdapter -VMName $vm; Write-Host '[OK] 指令成功!已成功將虛擬機顯卡重新掛載 (1G/4G)!' -ForegroundColor Green"

echo.
echo ===================================================
echo [!] 開機前跑完!顯卡已成功配對!
echo [!] 提示:6 台 VM 同開的 High MMIO 需求只有 24GB
echo      (原 8G 版本需要 48GB,壓力大)
echo ===================================================
pause
