# =========================================================
#  Host_Share.ps1  v1.2 -  主機端 SMB 共享一鍵建置
#  v1.2 改進:
#    - 自動設定 NTFS Everyone 權限
#    - 自動關閉密碼保護共享(伺服端登錄檔)
#    - 產生的 VM_Share_Connect.bat 自動修 VM 端 UAC / guest 問題
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

W-Title '主機端 SMB 共享建置工具 v1.2'

# =========================================================
#  0. 取得主機 IP
# =========================================================
W-Step '偵測主機 IP'
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
$raw = Read-Host '請選擇要給 VM 連接的 IP 編號'
if (-not ($raw -as [int]) -or [int]$raw -lt 1 -or [int]$raw -gt $hostIps.Count) {
    W-Err '無效'
    exit 1
}
$hostIp = $hostIps[[int]$raw - 1].IPAddress
W-OK ('使用主機 IP: ' + $hostIp)

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
#  2. NTFS 權限(v1.2 新增)— 讓 Everyone 能進
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
Write-Host '  [2] 讀寫  - VM 可讀可寫 (雙向檔案交換用)'
$pm = Read-Host '請選擇'
if ($pm -eq '2') {
    $shareAccess = 'Change'
    $modeName = '讀寫'
} else {
    $shareAccess = 'Read'
    $modeName = '唯讀'
}
W-OK ('權限模式: ' + $modeName)

# =========================================================
#  4. 建立 SMB 共享
# =========================================================
W-Step ('建立 SMB 共享: \\{0}\{1}' -f $hostIp, $shareName)
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
#  5. 伺服端登錄檔(v1.2 新增)— 關密碼保護共享
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
#  7. 產生 VM 端一鍵連接 bat(v1.2 大升級)
# =========================================================
W-Step '產生 VM 端 VM_Share_Connect.bat'

$vmConnectBat = @"
@echo off
REM ============================================================
REM  VM_Share_Connect.bat v1.2 (auto-generated by Host_Share.ps1)
REM  Run this INSIDE VM as Administrator
REM  Auto-fixes:
REM    - AllowInsecureGuestAuth    (SMB guest login block)
REM    - EnableLinkedConnections   (UAC admin/user token split)
REM    - Clears stuck Z: mappings
REM    - Connects Z: drive to host share
REM ============================================================
title VM Share Auto-Connect
color 0B

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Please right-click and Run as Administrator
    echo.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  VM to Host Share Auto-Connect
echo  Host:  \\$hostIp\$shareName
echo ============================================================
echo.

echo [1/6] Enable SMB guest auth (AllowInsecureGuestAuth)...
reg add "HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f >nul

echo [2/6] Enable UAC linked connections (EnableLinkedConnections)...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f >nul

echo [3/6] Clear any stuck Z: and Y: mappings...
net use Z: /delete /y >nul 2>&1
net use Y: /delete /y >nul 2>&1

echo [4/6] Restart LanmanWorkstation service...
net stop LanmanWorkstation /y >nul 2>&1
net start LanmanWorkstation >nul 2>&1

echo [5/6] Connect Z: drive...
net use Z: \\$hostIp\$shareName /PERSISTENT:YES
if errorlevel 1 goto CONN_FAILED

echo [6/6] Done!
echo.
echo ============================================================
echo [+] Connected successfully
echo [+] Z: -^> \\$hostIp\$shareName
echo ============================================================
echo.
echo If File Explorer does NOT show Z: drive:
echo   -^> This is first-time EnableLinkedConnections setup
echo   -^> Please REBOOT the VM once, then it will show up
echo.
start explorer Z:\
pause
exit /b 0

:CONN_FAILED
echo.
echo ============================================================
echo [X] Connection failed. Diagnosis:
echo ============================================================
echo.
echo  1. Can you ping the host?   ping $hostIp
echo  2. Host firewall blocking SMB? Check on host side
echo  3. Host share exists?       net view \\$hostIp
echo.
pause
exit /b 1
"@

$vmBatPath = Join-Path $sharePath 'VM_Share_Connect.bat'
Set-Content -Path $vmBatPath -Value $vmConnectBat -Encoding ASCII
W-OK ('寫入: ' + $vmBatPath)

# README
$readme = @"
# VM 共享資料夾說明 v1.2

## 主機端(已建置完成)
- 共享路徑 : $sharePath
- 共享網址 : \\$hostIp\$shareName
- 權限模式 : $modeName
- NTFS 權限: Everyone 讀寫 V
- 密碼保護 : 已關閉 V

## VM 端使用方式
1. 開啟 VM
2. VM 檔案總管進入 \\$hostIp\$shareName
3. 把 VM_Share_Connect.bat 複製到 VM 桌面
4. 右鍵「以系統管理員身分執行」
5. 第一次執行後,**重開 VM 一次**讓 EnableLinkedConnections 生效
6. 重開後就會在檔案總管看到 Z: 槽

## 為什麼要重開 VM?
EnableLinkedConnections 註冊表要開機時才讀取,設完不重開的話:
- 系統管理員 PowerShell 看得到 Z:
- 檔案總管(一般使用者權限)看不到 Z:

重開後兩邊就會同步。

## 移除共享(主機端以系統管理員 PowerShell)
    Remove-SmbShare -Name $shareName -Force
"@
Set-Content -Path (Join-Path $sharePath 'README.txt') -Value $readme -Encoding UTF8
W-OK '說明文件已寫入'

# =========================================================
#  8. 總結
# =========================================================
W-Title 'v1.2 共享建立完成'
Write-Host ''
Write-Host '主機端:' -ForegroundColor White
W-Info ('路徑     : ' + $sharePath)
W-Info ('網址     : \\{0}\{1}' -f $hostIp, $shareName)
W-Info ('權限     : ' + $modeName)
W-Info ('NTFS     : Everyone 已授權')
W-Info ('密碼保護 : 已關閉')
Write-Host ''
Write-Host 'VM 端:' -ForegroundColor White
Write-Host '  1. 開 VM,進檔案總管 -> \\' + $hostIp + '\' + $shareName
Write-Host '  2. 複製 VM_Share_Connect.bat 到 VM 桌面'
Write-Host '  3. 右鍵「以系統管理員身分執行」'
Write-Host '  4. ★ 第一次執行完,重開 VM 一次(UAC 設定要重開生效)'
Write-Host '  5. 重開後就會看到 Z: 槽,檔案總管也看得到'
Write-Host ''
Write-Host '小提示:' -ForegroundColor Yellow
Write-Host '  之後要重連(譬如換 IP 了),再跑一次 VM_Share_Connect.bat 就行'
Write-Host '  這支 bat 會自動處理所有 Win10 SMB 連線的坑'
Write-Host ''

$open = Read-Host '要立即開啟共享資料夾嗎?(Y/N)'
if ($open -match '^[Yy]') { Start-Process explorer.exe -ArgumentList $sharePath }
