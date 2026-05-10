@echo off
chcp 65001 >nul
title 虛擬機專用 - 精準抓取實體機顯卡驅動 V5
color 0B

:: 1. 檢查系統管理員權限
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo ===================================================
    echo [警告] 權限不足！
    echo 請對此檔案按右鍵，選擇「以系統管理員身分執行」!
    echo ===================================================
    pause
    exit /b
)

echo ===================================================
echo     正在準備跨越次元... 精準抓取與分流驅動檔案！
echo ===================================================
echo.

:: 2. 讓使用者輸入實體機的 IP
set /p hostIP="👉 請輸入你實體機的 IP (例如 192.168.1.236，輸入完按 Enter): "

if "%hostIP%"=="" (
    echo [錯誤] IP 不能為空！請重新執行。
    pause
    exit /b
)

:: 3. 設定來源與雙重目標路徑
:: 假設實體機共用的資料夾叫做 Share_folder
set source=\\%hostIP%\Share_folder
set targetRepo=C:\Windows\System32\HostDriverStore\FileRepository
set targetDll=C:\Windows\System32

echo.
echo 🔧 正在虛擬機內建立底層資料夾...
mkdir "%targetRepo%" 2>nul

echo 🚀 開始自動分流抓取檔案...
echo.

:: 4. 執行精準複製 (使用萬用字元自動篩選)
echo [1/2] 正在把 nv_dispi 核心驅動資料夾送進 FileRepository...
:: 這裡只抓開頭是 nv_dispi 的資料夾
xcopy "%source%\nv_dispi*" "%targetRepo%\" /E /I /H /Y /C

echo.
echo [2/2] 正在把 nvapi64 等 DLL 靈魂檔送進 System32 根目錄...
:: 這裡只抓附檔名是 .dll 的檔案
xcopy "%source%\*.dll" "%targetDll%\" /I /H /Y /C

:: ==========================================
:: 5. 【防呆機制】檢查複製是否成功
:: ==========================================
if %errorlevel% neq 0 (
    color 0C
    echo.
    echo ===================================================
    echo ❌ [致命錯誤] 檔案抓取失敗！請檢查權限或路徑。
    echo.
    echo 🔍 請檢查以下三點：
    echo 1. 實體機 IP 【 %hostIP% 】 是否輸入正確？
    echo 2. 實體機桌面的【 Share_folder 】是否有設定「共用」？
    echo 3. 實體機的「密碼保護的共用」是否已經關閉？
    echo ===================================================
    pause
    exit /b
)

:: 6. 成功才會走到這裡
color 0A
echo.
echo ===================================================
echo 🎉 換血手術大功告成！檔案已經自動分流完畢！
echo ⚠️ 請立刻將這台虛擬機「重新啟動」，顯卡就會生效了！
echo ===================================================
pause