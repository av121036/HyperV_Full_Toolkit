@echo off
chcp 65001 >nul
title 虛擬機專用 - 終極裝置識別碼修改工具 (含系統介面)
color 0B

:: 1. 檢查權限
net session >nul 2>&1
if %errorlevel% NEQ 0 (
    echo ===================================================
    echo [警告] 權限不足！請右鍵「以系統管理員身分執行」!
    echo ===================================================
    pause
    exit /b
)

echo ===================================================
echo   Windows 終極底層指紋修改工具 (一次修改三組核心機碼)
echo ===================================================
echo.
echo 🔍 正在呼叫 PowerShell 生成全新的隨機識別碼...

:: 2. 生成標準格式的 GUID (無括號 與 有括號版本)
for /f %%a in ('powershell -NoProfile -Command "[guid]::NewGuid().ToString()"') do set rawGuid=%%a
set bracedGuid={%rawGuid%}

echo.
echo [1/3] 寫入 Cryptography MachineGuid (防外掛與第三方軟體主要目標)
reg add "HKLM\SOFTWARE\Microsoft\Cryptography" /v MachineGuid /t REG_SZ /d "%rawGuid%" /f >nul

echo [2/3] 寫入 SQMClient MachineId (Windows 系統資訊介面顯示用)
reg add "HKLM\SOFTWARE\Microsoft\SQMClient" /v MachineId /t REG_SZ /d "%bracedGuid%" /f >nul

echo [3/3] 寫入 Hardware Profiles GUID (硬體設定檔特徵碼)
reg add "HKLM\SYSTEM\CurrentControlSet\Control\IDConfigDB\Hardware Profiles\0001" /v HwProfileGuid /t REG_SZ /d "%bracedGuid%" /f >nul

if %errorlevel% equ 0 (
    color 0A
    echo.
    echo ===================================================
    echo 🎉 終極修改成功！
    echo 你的全新系統裝置識別碼為:
    echo %rawGuid%
    echo.
    echo ⚠️ 系統必須重新啟動，UI 介面與底層才會完全刷新！
    echo ===================================================
    pause
    shutdown /r /t 0
) else (
    color 0C
    echo [錯誤] 寫入失敗，請檢查防毒軟體攔截。
    pause
)