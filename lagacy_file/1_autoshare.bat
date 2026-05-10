@echo off
chcp 65001 >nul
:: 檢查是否以系統管理員身分執行
net session >nul 2>&1
if %errorLevel% == 0 (
    echo [成功] 已取得系統管理員權限。
) else (
    echo [錯誤] 權限不足！請對著這個 .bat 檔案按右鍵，選擇「以系統管理員身分執行」。
    pause
    exit /b 1
)

echo ===================================================
echo   NVIDIA 驅動程式共用資料夾 自動設定腳本
echo ===================================================

set "TARGET_DIR=%USERPROFILE%\Desktop\Share_folder"

:: 1. 建立資料夾
echo.
echo [1/5] 正在桌面上建立 Share_folder...
if not exist "%TARGET_DIR%" (
    mkdir "%TARGET_DIR%"
)

:: 2 & 3. 搜尋並複製 nv_dispi 相關的顯示卡核心驅動資料夾
echo [2/5] 正在複製 NVIDIA 顯示卡核心驅動資料夾...
for /d %%D in ("C:\Windows\System32\DriverStore\FileRepository\nv_dispig.inf_amd64_*") do (
    echo   - 複製 %%~nxD...
    xcopy "%%D" "%TARGET_DIR%\%%~nxD\" /E /I /H /Y >nul
)
:: (備用) 兼容部分系統可能命名為 nv_dispi 開頭
for /d %%D in ("C:\Windows\System32\DriverStore\FileRepository\nv_dispi.inf_amd64_*") do (
    echo   - 複製 %%~nxD...
    xcopy "%%D" "%TARGET_DIR%\%%~nxD\" /E /I /H /Y >nul
)
:: (備用) 兼容部分系統可能命名為 nvmdi 開頭
for /d %%D in ("C:\Windows\System32\DriverStore\FileRepository\nvmdi.inf_amd64_*") do (
    echo   - 複製 %%~nxD...
    xcopy "%%D" "%TARGET_DIR%\%%~nxD\" /E /I /H /Y >nul
)

:: 4. 複製 dll 檔案
echo [3/5] 正在複製 NVIDIA DLL 檔案...
copy /Y "C:\Windows\System32\nvapi64.dll" "%TARGET_DIR%\" >nul
copy /Y "C:\Windows\System32\nvapi.dll" "%TARGET_DIR%\" >nul
copy /Y "C:\Windows\System32\nvcompiler.dll" "%TARGET_DIR%\" >nul
copy /Y "C:\Windows\System32\nvoglv64.dll" "%TARGET_DIR%\" >nul
copy /Y "C:\Windows\System32\nvoglv32.dll" "%TARGET_DIR%\" >nul

:: 5~9. 設定資料夾共用與 Everyone 讀取權限
echo [4/5] 正在設定資料夾共用與 Everyone 讀取權限...
net share Share_folder /delete >nul 2>&1
net share Share_folder="%TARGET_DIR%" /GRANT:Everyone,READ >nul
:: 設定 NTFS 安全性權限也允許 Everyone 讀取
icacls "%TARGET_DIR%" /grant Everyone:(OI)(CI)R /T /Q >nul

:: 控制台 1~6. 關閉密碼保護的共用 (透過修改 Windows 登錄檔達成)
echo [5/5] 正在關閉「密碼保護的共用」...
reg add "HKLM\SYSTEM\CurrentControlSet\Control\Lsa" /v "everyoneincludesanonymous" /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" /v "restrictnullsessaccess" /t REG_DWORD /d 0 /f >nul

echo.
echo ===================================================
echo   全部設定完成！
echo   請檢查桌面的 Share_folder 是否有成功放入檔案。
echo   (註：網路共用設定若未即時生效，請重新開機一次)
echo ===================================================
pause