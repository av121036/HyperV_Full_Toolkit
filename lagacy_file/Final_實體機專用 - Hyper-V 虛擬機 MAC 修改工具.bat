@echo off
chcp 65001 >nul
title 實體機專用 - Hyper-V 虛擬機 MAC 修改工具
color 0B

:: 1. 檢查系統管理員權限
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo ===================================================
    echo [警告] 權限不足！請右鍵「以系統管理員身分執行」!
    echo ===================================================
    pause
    exit /b
)

echo ===================================================
echo      Hyper-V 虛擬機 MAC 位址隨機生成與寫入工具
echo          (自動套用前綴: 04:D4:C4 華碩網卡)
echo ===================================================
echo.
echo ⚠️ 注意：本腳本必須在「實體主機 (Host)」上執行！
echo 建議在虛擬機【關機狀態】下進行修改最為穩定。
echo.

:: 2. 輸入虛擬機名稱
:InputLoop
set /p vmName="👉 請輸入你要修改 MAC 的「虛擬機名稱」: "
if "%vmName%"=="" (
    echo [錯誤] 虛擬機名稱不能為空，請重新輸入！
    echo.
    goto InputLoop
)

echo.
echo 🔍 正在生成隨機 MAC 並修改 Hyper-V 底層設定...

:: 3. 呼叫 PowerShell 生成 04D4C4 開頭的隨機 MAC，並直接寫入 Hyper-V
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; try { $mac = '04D4C4' + (-join ((1..3) | ForEach-Object { '{0:X2}' -f (Get-Random -Minimum 0 -Maximum 256) })); Set-VMNetworkAdapter -VMName '%vmName%' -StaticMacAddress $mac; Write-Host ''; Write-Host '🎉 寫入成功！' -ForegroundColor Green; Write-Host \"虛擬機名稱: %vmName%\" -ForegroundColor Cyan; Write-Host \"全新靜態 MAC: $mac\" -ForegroundColor Yellow; Write-Host '' } catch { Write-Host '' ; Write-Host \"[錯誤] 無法修改！請確認輸入的虛擬機名稱是否正確，或 Hyper-V 服務是否正常。\" -ForegroundColor Red; Write-Host \"錯誤詳細資訊: $($_.Exception.Message)\" -ForegroundColor DarkRed; Write-Host '' }"

echo ===================================================
pause