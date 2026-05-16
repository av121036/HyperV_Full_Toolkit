@echo off
chcp 950 >nul
title Windows Defender 管理工具

:: ===== 自動請求系統管理員權限 =====
net session >nul 2>&1
if %errorLevel% neq 0 (
    echo 需要系統管理員權限，正在請求提權...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

:MENU
cls
echo ============================================
echo        Windows Defender 管理工具
echo ============================================
echo.

:: 檢查防竄改保護狀態並提示
for /f "delims=" %%i in ('powershell -Command "(Get-MpComputerStatus).IsTamperProtected"') do set TAMPER=%%i
if /i "%TAMPER%"=="True" (
    echo  [!] 警告: 防竄改保護目前為「開啟」狀態
    echo  [!] 即時防護的開關指令會無效，必須先手動關閉防竄改保護
    echo  [!] 路徑: Windows 安全性 ^> 病毒與威脅防護 ^> 管理設定 ^> 防竄改保護
    echo.
)

:: 顯示目前即時防護狀態
for /f "delims=" %%i in ('powershell -Command "(Get-MpComputerStatus).RealTimeProtectionEnabled"') do set RTP=%%i
if /i "%RTP%"=="True" (
    echo  目前即時防護: 開啟
) else (
    echo  目前即時防護: 關閉
)
echo.
echo ============================================
echo  [1] 關閉即時防護
echo  [2] 開啟即時防護
echo  [3] 新增排除資料夾
echo  [4] 移除排除資料夾
echo  [5] 查看目前排除清單
echo  [6] 查看 Defender 完整狀態
echo  [7] 開啟 Windows 安全性 (手動關閉防竄改保護)
echo  [0] 離開
echo ============================================
set /p choice=請選擇功能 [0-7]: 

if "%choice%"=="1" goto DISABLE_RTP
if "%choice%"=="2" goto ENABLE_RTP
if "%choice%"=="3" goto ADD_EXCLUSION
if "%choice%"=="4" goto REMOVE_EXCLUSION
if "%choice%"=="5" goto LIST_EXCLUSIONS
if "%choice%"=="6" goto STATUS
if "%choice%"=="7" goto OPEN_SECURITY
if "%choice%"=="0" exit /b
goto MENU

:DISABLE_RTP
echo.
echo 正在關閉即時防護...
powershell -Command "Set-MpPreference -DisableRealtimeMonitoring $true" 2>nul

:: 驗證是否真的生效
timeout /t 1 /nobreak >nul
for /f "delims=" %%i in ('powershell -Command "(Get-MpComputerStatus).RealTimeProtectionEnabled"') do set RESULT=%%i

if /i "%RESULT%"=="False" (
    echo [成功] 即時防護已確實關閉
) else (
    echo [失敗] 指令已執行但即時防護仍為開啟狀態
    echo.
    echo 原因通常是「防竄改保護」啟用中，請選擇 [7] 開啟 Windows 安全性手動關閉
)
echo.
pause
goto MENU

:ENABLE_RTP
echo.
echo 正在開啟即時防護...
powershell -Command "Set-MpPreference -DisableRealtimeMonitoring $false" 2>nul

timeout /t 1 /nobreak >nul
for /f "delims=" %%i in ('powershell -Command "(Get-MpComputerStatus).RealTimeProtectionEnabled"') do set RESULT=%%i

if /i "%RESULT%"=="True" (
    echo [成功] 即時防護已確實開啟
) else (
    echo [失敗] 指令已執行但即時防護仍為關閉狀態
)
echo.
pause
goto MENU

:ADD_EXCLUSION
echo.
echo ============================================
echo            新增排除資料夾
echo ============================================
echo.
echo 請輸入完整資料夾路徑 (例如: C:\MyFolder)
echo 直接按 Enter 可開啟資料夾選擇視窗
echo.
set /p folder=路徑: 

if "%folder%"=="" (
    echo 開啟資料夾選擇視窗...
    for /f "delims=" %%i in ('powershell -Command "Add-Type -AssemblyName System.Windows.Forms; $f = New-Object System.Windows.Forms.FolderBrowserDialog; $f.Description = '選擇要排除的資料夾'; if ($f.ShowDialog() -eq 'OK') { $f.SelectedPath }"') do set folder=%%i
)

if "%folder%"=="" (
    echo [取消] 未選擇任何資料夾
    pause
    goto MENU
)

if not exist "%folder%" (
    echo [錯誤] 資料夾不存在: %folder%
    pause
    goto MENU
)

echo.
echo 正在新增排除: %folder%
powershell -Command "Add-MpPreference -ExclusionPath '%folder%'" 2>nul

:: 驗證
powershell -Command "if ((Get-MpPreference).ExclusionPath -contains '%folder%') { exit 0 } else { exit 1 }"
if %errorLevel% equ 0 (
    echo [成功] 已新增排除資料夾
) else (
    echo [失敗] 排除清單中找不到此路徑，可能被防竄改保護阻擋
)
echo.
pause
goto MENU

:REMOVE_EXCLUSION
echo.
echo ============================================
echo            移除排除資料夾
echo ============================================
echo.
echo 目前排除清單：
powershell -Command "(Get-MpPreference).ExclusionPath"
echo.
set /p folder=請輸入要移除的完整路徑: 

if "%folder%"=="" (
    echo [取消] 未輸入路徑
    pause
    goto MENU
)

powershell -Command "Remove-MpPreference -ExclusionPath '%folder%'" 2>nul

powershell -Command "if ((Get-MpPreference).ExclusionPath -notcontains '%folder%') { exit 0 } else { exit 1 }"
if %errorLevel% equ 0 (
    echo [成功] 已移除排除資料夾
) else (
    echo [失敗] 移除失敗
)
echo.
pause
goto MENU

:LIST_EXCLUSIONS
echo.
echo ============================================
echo          目前排除資料夾清單
echo ============================================
echo.
powershell -Command "(Get-MpPreference).ExclusionPath"
echo.
pause
goto MENU

:STATUS
echo.
echo ============================================
echo        Windows Defender 完整狀態
echo ============================================
echo.
powershell -Command "Get-MpComputerStatus | Select-Object AntivirusEnabled, RealTimeProtectionEnabled, IoavProtectionEnabled, OnAccessProtectionEnabled, IsTamperProtected, AMRunningMode | Format-List"
echo.
echo 說明:
echo   IsTamperProtected = True  : 防竄改保護開啟 (會阻擋指令修改)
echo   AMRunningMode = Normal    : Defender 為主要防毒
echo   AMRunningMode = Passive   : 已被其他防毒接管
echo.
pause
goto MENU

:OPEN_SECURITY
echo.
echo 正在開啟 Windows 安全性...
echo 請手動操作: 病毒與威脅防護 ^> 管理設定 ^> 關閉「防竄改保護」
start windowsdefender://threatsettings
echo.
pause
goto MENU
