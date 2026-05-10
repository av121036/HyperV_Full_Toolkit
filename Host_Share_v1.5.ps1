# =========================================================
#  Host_Share_v1.5.ps1 -  主機端 SMB 共享一鍵建置
#  v1.5 改進:
#    - 檔案編碼修正:UTF-8 with BOM + CRLF,避免繁中 Windows
#      PS5.1 用 Big5 誤讀,here-string 不會被破壞
#    - 版號與 toolkit 主目錄 (HyperV_Full_Toolkit_v1.5) 對齊
#    - 互動提示加上預設值,Enter 直接走最常用流程:
#        * 權限模式 -> 預設「讀寫」
#        * 完成後 -> 預設立即開啟共享資料夾
#  v1.3:
#    - VM 端改用「主機名稱」連線,IP 變動不再失效
#    - VM 端 bat 自動雙重備援:先試名稱,失敗用 IP
#    - 多產生 Update_Host_IP bat 給 VM 緊急換 IP 用
#  v1.2:
#    - 自動設定 NTFS Everyone 權限
#    - 自動關閉密碼保護共享
#    - VM 端 bat 自動修 UAC / guest 問題
# =========================================================

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

function W-Title($t) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host (" $t") -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}
function W-Step($t) { Write-Host "[*] $t" -ForegroundColor Yellow }
function W-OK($t)   { Write-Host "[+] $t" -ForegroundColor Green }
function W-Err($t)  { Write-Host "[X] $t" -ForegroundColor Red }
function W-Info($t) { Write-Host "    $t" -ForegroundColor Gray }

W-Title '主機端 SMB 共享建置工具 v1.5'

# =========================================================
#  0a. 取得主機名稱(v1.5 新增)
# =========================================================
$hostName = $env:COMPUTERNAME
W-OK ('主機名稱: ' + $hostName + '  (VM 將優先用名稱連線,不怕 IP 變)')

# =========================================================
#  0b. 取得主機 IP(備援用)
# =========================================================
W-Step '偵測主機 IP (備援用)'
$hostIps = @()
try {
    $hostIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop `
        | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -ne '127.0.0.1' } `
        | Where-Object { $_.PrefixOrigin -eq 'Manual' -or $_.PrefixOrigin -eq 'Dhcp' } `
        | Sort-Object InterfaceMetric
} catch {}

if ($hostIps.Count -eq 0) {
    W-Err '找不到任何網卡 IP'
    exit 1
}

Write-Host ''
Write-Host '主機網卡清單:' -ForegroundColor White
for ($i = 0; $i -lt $hostIps.Count; $i++) {
    $ip = $hostIps[$i]
    $tag = ''
    if ($ip.InterfaceAlias -match 'vEthernet|Hyper-V|Default Switch') { $tag = '  << VM 用這條' }
    Write-Host ('  [{0}] {1,-40} {2}{3}' -f ($i + 1), $ip.InterfaceAlias, $ip.IPAddress, $tag)
}
Write-Host ''
$raw = Read-Host '請選擇要給 VM 連接的 IP 編號 (備援用,平常 VM 會優先用主機名稱)'
if (-not ($raw -as [int]) -or [int]$raw -lt 1 -or [int]$raw -gt $hostIps.Count) {
    W-Err '無效'
    exit 1
}
$hostIp = $hostIps[[int]$raw - 1].IPAddress
W-OK ('備援主機 IP: ' + $hostIp)

# =========================================================
#  1. 共享資料夾
# =========================================================
Write-Host ''
$defaultPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'share_folder'
Write-Host ('預設路徑: ' + $defaultPath) -ForegroundColor Gray
$custom = Read-Host '要改路徑嗎?(Enter 用預設)'
$sharePath = if ([string]::IsNullOrWhiteSpace($custom)) { $defaultPath } else { $custom }

if (-not (Test-Path $sharePath)) {
    W-Step ('建立資料夾 ' + $sharePath)
    New-Item -Path $sharePath -ItemType Directory -Force | Out-Null
}
W-OK ('共享資料夾: ' + $sharePath)

# =========================================================
#  2. NTFS 權限 — 讓 Everyone 能進
# =========================================================
W-Step '設定 NTFS 權限 (Everyone 可讀寫)'
try {
    $null = icacls $sharePath /grant "Everyone:(OI)(CI)M" /T 2>&1
    W-OK 'NTFS 權限設定完成'
} catch { W-Err ('NTFS 權限失敗: ' + $_.Exception.Message) }

# =========================================================
#  3. 權限模式
# =========================================================
$shareName = 'share_folder'
Write-Host ''
Write-Host '權限模式:' -ForegroundColor White
Write-Host '  [1] 唯讀  - VM 只能讀,不能寫 (天堂安裝檔分發用)'
Write-Host '  [2] 讀寫  - VM 可讀可寫 (雙向檔案交換用) [預設]'
$pm = Read-Host '請選擇 (Enter 用預設 = 2 讀寫)'
if ($pm -eq '1') {
    $shareAccess = 'Read'
    $modeName = '唯讀'
} else {
    $shareAccess = 'Change'
    $modeName = '讀寫'
}
W-OK ('權限模式: ' + $modeName)

# =========================================================
#  4. 建立 SMB 共享
# =========================================================
W-Step ('建立 SMB 共享: \\{0}\{1}  (或 \\{2}\{1})' -f $hostName, $shareName, $hostIp)
try {
    Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue | Remove-SmbShare -Force -ErrorAction SilentlyContinue

    if ($shareAccess -eq 'Read') {
        New-SmbShare -Name $shareName -Path $sharePath -ReadAccess 'Everyone' -Description 'VM Shared Folder (RO)' | Out-Null
    } else {
        New-SmbShare -Name $shareName -Path $sharePath -ChangeAccess 'Everyone' -Description 'VM Shared Folder (RW)' | Out-Null
    }
    W-OK 'SMB 共享建立成功'
} catch {
    W-Err ('共享建立失敗: ' + $_.Exception.Message)
    exit 1
}

# =========================================================
#  5. 伺服端登錄檔 — 關密碼保護共享
# =========================================================
W-Step '關閉密碼保護共享 (伺服端)'
try {
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
        -Name 'EveryoneIncludesAnonymous' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' `
        -Name 'RestrictNullSessAccess' -Value 0 -PropertyType DWord -Force | Out-Null
    W-OK '登錄檔已設定'
} catch { W-Err ('登錄檔失敗: ' + $_.Exception.Message) }

W-Step '重啟 SMB Server 服務'
try {
    Restart-Service LanmanServer -Force -ErrorAction Stop
    W-OK 'LanmanServer 已重啟'
} catch { W-Err ('重啟失敗: ' + $_.Exception.Message) }

# =========================================================
#  6. 防火牆
# =========================================================
W-Step '防火牆放行檔案及印表機共用'
try {
    Get-NetFirewallRule -DisplayGroup '檔案及印表機共用' -ErrorAction SilentlyContinue `
        | Set-NetFirewallRule -Enabled True -Profile Any -ErrorAction SilentlyContinue
    Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue `
        | Set-NetFirewallRule -Enabled True -Profile Any -ErrorAction SilentlyContinue
    W-OK '防火牆規則已啟用'
} catch { W-Err ('防火牆失敗: ' + $_.Exception.Message) }

# =========================================================
#  6b. 防火牆放行 ICMP (讓 VM 能 ping 主機名稱)
# =========================================================
W-Step '防火牆放行 ICMP (給 VM ping 用)'
try {
    netsh advfirewall firewall add rule name="ICMP Allow incoming V4" protocol=icmpv4:8,any dir=in action=allow 2>&1 | Out-Null
    W-OK 'ICMP 已放行'
} catch { W-Err ('ICMP 放行失敗: ' + $_.Exception.Message) }

# =========================================================
#  7. 產生 VM 端一鍵連接 bat (v1.5 - 名稱優先,IP 備援)
# =========================================================
W-Step '產生 VM 端 VM_Share_Connect_v1.5.bat'

$vmConnectBat = @"
@echo off
REM ============================================================
REM  VM_Share_Connect_v1.5.bat (auto-generated by Host_Share_v1.5.ps1)
REM  Run this INSIDE VM as Administrator
REM
REM  v1.5 改進:
REM    - 優先用主機名稱連線,主機 IP 變動也不怕
REM    - 名稱失敗自動 fallback 用備援 IP
REM    - 自動偵測當下主機 IP (透過 ping 名稱)
REM
REM  Auto-fixes:
REM    - AllowInsecureGuestAuth    (SMB guest login block)
REM    - EnableLinkedConnections   (UAC admin/user token split)
REM    - Clears stuck Z: mappings
REM ============================================================
title VM Share Auto-Connect v1.5
color 0B

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Please right-click and Run as Administrator
    echo.
    pause
    exit /b 1
)

set "HOST_NAME=$hostName"
set "HOST_IP_BACKUP=$hostIp"
set "SHARE_NAME=$shareName"

echo.
echo ============================================================
echo  VM to Host Share Auto-Connect v1.5
echo  Host name : %HOST_NAME%   (preferred, IP-change proof)
echo  Backup IP : %HOST_IP_BACKUP%
echo  Share     : %SHARE_NAME%
echo ============================================================
echo.

echo [1/7] Enable SMB guest auth (AllowInsecureGuestAuth)...
reg add "HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f >nul

echo [2/7] Enable UAC linked connections (EnableLinkedConnections)...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f >nul

echo [3/7] Clear any stuck Z: and Y: mappings...
net use Z: /delete /y >nul 2>&1
net use Y: /delete /y >nul 2>&1

echo [4/7] Restart LanmanWorkstation service...
net stop LanmanWorkstation /y >nul 2>&1
net start LanmanWorkstation >nul 2>&1

echo [5/7] Try connecting via host name: \\%HOST_NAME%\%SHARE_NAME% ...
net use Z: \\%HOST_NAME%\%SHARE_NAME% /PERSISTENT:YES >nul 2>&1
if not errorlevel 1 (
    echo     [+] Connected via host name
    goto CONN_OK
)

echo     [!] Name resolution failed, trying backup IP...
echo.
echo [6/7] Try connecting via backup IP: \\%HOST_IP_BACKUP%\%SHARE_NAME% ...
net use Z: \\%HOST_IP_BACKUP%\%SHARE_NAME% /PERSISTENT:YES >nul 2>&1
if not errorlevel 1 (
    echo     [+] Connected via backup IP
    echo     [!] WARN: Host name failed - consider running Update_Host_IP_v1.5.bat
    echo              if host IP has changed permanently
    goto CONN_OK
)

echo     [!] Backup IP also failed, trying to auto-detect host IP...
echo.
echo [7/7] Auto-detect host IP via ping %HOST_NAME% ...
set "DETECTED_IP="
for /f "tokens=2 delims=[]" %%a in ('ping -n 1 -4 %HOST_NAME% 2^>nul ^| findstr /C:"["') do set "DETECTED_IP=%%a"
if defined DETECTED_IP (
    echo     Detected host IP: %DETECTED_IP%
    net use Z: \\%DETECTED_IP%\%SHARE_NAME% /PERSISTENT:YES >nul 2>&1
    if not errorlevel 1 (
        echo     [+] Connected via auto-detected IP
        goto CONN_OK
    )
)

goto CONN_FAILED

:CONN_OK
echo.
echo ============================================================
echo [+] Connected successfully
echo [+] Z: -^> Host share %SHARE_NAME%
echo ============================================================
echo.
echo If File Explorer does NOT show Z: drive:
echo   -^> First-time EnableLinkedConnections setup
echo   -^> Please REBOOT the VM once, then it will show up
echo.
start explorer Z:\
pause
exit /b 0

:CONN_FAILED
echo.
echo ============================================================
echo [X] All connection attempts failed. Diagnosis:
echo ============================================================
echo.
echo  1. Can VM reach host?
echo        ping %HOST_NAME%
echo        ping %HOST_IP_BACKUP%
echo.
echo  2. If host IP has permanently changed:
echo        Run Update_Host_IP_v1.5.bat (in this folder)
echo        and enter the new IP
echo.
echo  3. Check on host side:
echo        - SMB share exists?  (PowerShell: Get-SmbShare)
echo        - Firewall blocking? (File and Printer Sharing rule)
echo.
echo  4. Verify share visible from VM:
echo        net view \\%HOST_NAME%
echo        net view \\%HOST_IP_BACKUP%
echo.
pause
exit /b 1
"@

$vmBatPath = Join-Path $sharePath 'VM_Share_Connect_v1.5.bat'
Set-Content -Path $vmBatPath -Value $vmConnectBat -Encoding ASCII
W-OK ('寫入: ' + $vmBatPath)

# =========================================================
#  7b. 產生 VM 端「緊急更新主機 IP」bat (v1.5 新增)
# =========================================================
W-Step '產生 VM 端 Update_Host_IP_v1.5.bat (緊急換 IP 用)'

$updateIpBat = @"
@echo off
REM ============================================================
REM  Update_Host_IP_v1.5.bat
REM  Run INSIDE VM as Administrator
REM  Use when: host IP changed AND name resolution doesn't work
REM
REM  This script writes the new host IP into VM's hosts file,
REM  so \\$hostName\$shareName will resolve correctly again.
REM ============================================================
title Update Host IP Mapping v1.5
color 0E

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Please right-click and Run as Administrator
    pause
    exit /b 1
)

set "HOST_NAME=$hostName"
set "SHARE_NAME=$shareName"
set "HOSTS_FILE=%SystemRoot%\System32\drivers\etc\hosts"

echo.
echo ============================================================
echo  Update host IP mapping for: %HOST_NAME%
echo ============================================================
echo.
echo  This will edit VM's hosts file:
echo    %HOSTS_FILE%
echo.

set /p NEW_IP="Enter new host IP (e.g. 192.168.1.50): "
if "%NEW_IP%"=="" (
    echo [X] No IP entered, abort.
    pause
    exit /b 1
)

echo.
echo [1/3] Backup current hosts file...
copy /Y "%HOSTS_FILE%" "%HOSTS_FILE%.bak" >nul

echo [2/3] Remove old %HOST_NAME% entries...
findstr /v /i /c:"%HOST_NAME%" "%HOSTS_FILE%" > "%TEMP%\hosts.new"
copy /Y "%TEMP%\hosts.new" "%HOSTS_FILE%" >nul
del "%TEMP%\hosts.new" >nul 2>&1

echo [3/3] Add new mapping: %NEW_IP%  %HOST_NAME%
echo %NEW_IP%    %HOST_NAME%>> "%HOSTS_FILE%"

echo.
echo Flushing DNS cache...
ipconfig /flushdns >nul

echo.
echo ============================================================
echo [+] Done! Now testing...
echo ============================================================
ping -n 1 %HOST_NAME%
echo.
echo Now try running VM_Share_Connect_v1.5.bat again.
echo.
pause
exit /b 0
"@

$updateIpBatPath = Join-Path $sharePath 'Update_Host_IP_v1.5.bat'
Set-Content -Path $updateIpBatPath -Value $updateIpBat -Encoding ASCII
W-OK ('寫入: ' + $updateIpBatPath)

# =========================================================
#  8. README
# =========================================================
$readme = @"
# VM 共享資料夾說明 v1.5

## 主機端(已建置完成)
- 共享路徑   : $sharePath
- 主機名稱   : $hostName              <-- VM 優先用這個連
- 共享網址   : \\$hostName\$shareName  (推薦)
- 備援網址   : \\$hostIp\$shareName    (主機 IP 變動就會失效)
- 權限模式   : $modeName
- NTFS 權限  : Everyone V
- 密碼保護   : 已關閉 V

## v1.5 重點 — 解決「主機 IP 會變」的問題
VM 端 bat 連線優先順序:
1. 先用主機名稱 \\$hostName\$shareName  <-- IP 變了也不影響
2. 名稱失敗,改用建置時記錄的備援 IP
3. 還是失敗,自動 ping 主機名稱反查當下 IP 再連

只要主機名稱還能解析得到,IP 怎麼變都不用管。

## VM 端使用方式
1. 開啟 VM
2. VM 檔案總管進入 \\$hostName\$shareName  (或 \\$hostIp\$shareName)
3. 把 VM_Share_Connect_v1.5.bat 複製到 VM 桌面
4. 右鍵「以系統管理員身分執行」
5. 第一次執行後,**重開 VM 一次**讓 EnableLinkedConnections 生效
6. 重開後就會在檔案總管看到 Z: 槽

## 萬一主機名稱也解析不到怎麼辦?
通常名稱解析失敗發生於:VM 跨網段、NetBIOS 被關掉、用了 NAT 模式等。

解法 — 用 Update_Host_IP_v1.5.bat:
1. 確認主機目前的 IP (主機端打 ipconfig)
2. VM 端用系統管理員身份執行 Update_Host_IP_v1.5.bat
3. 輸入新 IP -> 它會把 \\$hostName 對應寫進 VM 的 hosts 檔
4. 之後 VM_Share_Connect_v1.5.bat 就會正常運作

以後主機 IP 再變,只要再跑一次 Update_Host_IP_v1.5.bat 改 IP 即可,
不用重新建置整個共享。

## 為什麼要重開 VM?
EnableLinkedConnections 註冊表要開機時才讀取,設完不重開的話:
- 系統管理員 PowerShell 看得到 Z:
- 檔案總管(一般使用者權限)看不到 Z:
重開後兩邊就會同步。

## 想徹底治本(可選):主機 IP 固定下來
- 在路由器後台設「DHCP 保留」,把主機 MAC 綁固定 IP
- 或主機網卡設靜態 IP
之後完全不用煩惱 IP 變動。

## 移除共享(主機端以系統管理員 PowerShell)
    Remove-SmbShare -Name $shareName -Force
"@
Set-Content -Path (Join-Path $sharePath 'README.txt') -Value $readme -Encoding UTF8
W-OK '說明文件已寫入'

# =========================================================
#  9. 總結
# =========================================================
W-Title 'v1.5 共享建立完成'
Write-Host ''
Write-Host '主機端:' -ForegroundColor White
W-Info ('路徑       : ' + $sharePath)
W-Info ('主機名稱   : ' + $hostName)
W-Info ('推薦網址   : \\{0}\{1}' -f $hostName, $shareName)
W-Info ('備援網址   : \\{0}\{1}' -f $hostIp, $shareName)
W-Info ('權限       : ' + $modeName)
W-Info ('NTFS       : Everyone 已授權')
W-Info ('密碼保護   : 已關閉')
Write-Host ''
Write-Host 'VM 端 (在虛擬機裡面執行):' -ForegroundColor White
Write-Host ('  1. VM 檔案總管 -> \\' + $hostName + '\' + $shareName)
Write-Host '  2. 把 VM_Share_Connect_v1.5.bat 複製到 VM 桌面'
Write-Host '  3. 右鍵「以系統管理員身分執行」'
Write-Host '  4. ★ 第一次執行完,重開 VM 一次(UAC 設定要重開生效)'
Write-Host '  5. 重開後就會看到 Z: 槽'
Write-Host ''
Write-Host '★ v1.5 賣點:' -ForegroundColor Green
Write-Host '  以後主機 IP 變了,直接重跑 VM_Share_Connect_v1.5.bat 即可'
Write-Host '  它會優先用主機名稱連,IP 變動完全無感'
Write-Host ''
Write-Host '  萬一主機名稱也解不到,跑 Update_Host_IP_v1.5.bat 輸入新 IP 即可'
Write-Host ''

$open = Read-Host '要立即開啟共享資料夾嗎? (Y/N,Enter 預設 = Y)'
if ($open -notmatch '^[Nn]') { Start-Process explorer.exe -ArgumentList $sharePath }
