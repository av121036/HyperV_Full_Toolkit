@echo off
chcp 65001 >nul
echo 開始複製檔案...

:: 自動抓取 bat 檔案所在的資料夾路徑
set "SOURCE=%~dp0"

:: 自動複製所有 nv_ 開頭的資料夾到 HostDriverStore\FileRepository
for /D %%F in ("%SOURCE%nv_*") do (
    echo 複製資料夾: %%~nxF
    xcopy /E /I /Y "%%F" "C:\Windows\System32\HostDriverStore\FileRepository\%%~nxF"
)

:: 複製 nvapi64.dll 到 System32（如果存在）
if exist "%SOURCE%nvapi64.dll" (
    echo 複製 nvapi64.dll
    copy /Y "%SOURCE%nvapi64.dll" "C:\Windows\System32\nvapi64.dll"
)

echo 完成！
pause
