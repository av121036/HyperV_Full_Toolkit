# =========================================================
#  VM_HostShortcut_v1.0.ps1
#
#  在 VM 內部執行 (admin)。
#
#  解決 Host_Share_v1.5 用完後的雞生蛋問題:
#    Host_Share 已經會自動產生 VM_Share_Connect_v1.5.bat 放進 share 裡,
#    但 VM 要先進到 share 才能執行它,而沒做 SMB 認證 fix 之前 VM 連
#    不上 share。
#
#  此腳本走完整流程:
#    1. 透過 Hyper-V Integration Services KVP 讀「主機名」(不靠 IP)
#    2. 寫入 VM 內 SMB / UAC 必要 registry (Host_Share 那批)
#    3. 測 \\<HostName>\share_folder 連線
#    4. 在 VM 桌面建立 "主機共用" 捷徑
#    5. (可選) 直接把 share 對應成 Z: 磁碟
# =========================================================

param(
    [string]$ShareName = 'share_folder',
    [switch]$MapDrive,
    [string]$DriveLetter = 'Z'
)

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
function W-Warn($t) { Write-Host "[!] $t" -ForegroundColor Yellow }

W-Title 'VM 主機共用捷徑自動配置 v1.0'

# =========================================================
#  預檢
# =========================================================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] 'Administrator')
if (-not $isAdmin) {
    W-Err '需要系統管理員權限 (要改 SMB / UAC registry)'
    exit 1
}

# =========================================================
#  1. 從 Hyper-V KVP 讀主機名
# =========================================================
W-Step '透過 Hyper-V Integration Services 讀取主機名'

$kvpPath = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'
$hostName = $null

if (Test-Path $kvpPath) {
    $kvp = Get-ItemProperty $kvpPath -ErrorAction SilentlyContinue
    if ($kvp.PhysicalHostName) {
        $hostName = $kvp.PhysicalHostName
        W-OK ("主機名 (Hyper-V KVP): $hostName")
    } elseif ($kvp.PhysicalHostNameFullyQualified) {
        $hostName = $kvp.PhysicalHostNameFullyQualified
        W-OK ("主機名 FQDN (Hyper-V KVP): $hostName")
    }
}

if (-not $hostName) {
    W-Warn 'Hyper-V KVP 讀不到主機名,改用 default gateway IP'
    $gw = (Get-NetIPConfiguration -ErrorAction SilentlyContinue |
           Where-Object { $_.IPv4DefaultGateway }).IPv4DefaultGateway.NextHop |
           Select-Object -First 1
    if ($gw) {
        $hostName = $gw
        W-OK ("Gateway IP: $hostName")
    } else {
        W-Err '完全找不到主機名 / Gateway,中止'
        exit 1
    }
}

# =========================================================
#  2. 寫 SMB / UAC registry (跟 VM_Share_Connect_v1.5 一致)
# =========================================================
W-Step '寫入 SMB / UAC 必要 registry'

try {
    # AllowInsecureGuestAuth - 讓 SMB guest 登入不被擋
    New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' `
        -Name 'AllowInsecureGuestAuth' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    W-OK '  AllowInsecureGuestAuth = 1'

    # EnableLinkedConnections - UAC token 共用,admin / user 都看得到 mapping
    if (-not (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System')) {
        New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Force | Out-Null
    }
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
        -Name 'EnableLinkedConnections' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    W-OK '  EnableLinkedConnections = 1'
} catch {
    W-Warn "registry 寫入有問題: $($_.Exception.Message)"
}

# =========================================================
#  3. 測試 share 連線
# =========================================================
W-Step ("測試 \\$hostName\$ShareName 連線")
$share = "\\$hostName\$ShareName"
$reachable = $false
try {
    if (Test-Path $share -ErrorAction SilentlyContinue) {
        $reachable = $true
        W-OK '連線成功'
    }
} catch {}

if (-not $reachable) {
    W-Warn '第一次測試失敗,嘗試 net use 強制 refresh...'
    & cmd /c "net use $share /persistent:no" 2>&1 | Out-Null
    Start-Sleep -Seconds 2
    if (Test-Path $share -ErrorAction SilentlyContinue) {
        $reachable = $true
        W-OK '第二次測試成功'
    }
}

if (-not $reachable) {
    W-Err '無法連到 share。可能原因:'
    W-Info '  - 主機尚未跑過 Host_Share_v1.5 (share 不存在)'
    W-Info '  - 主機防火牆擋 SMB (port 445)'
    W-Info '  - 名稱解析失敗 (試一下 ping ' + $hostName + ')'
    W-Info '  - 主機進階共用沒開 (Open_AdvancedSharing.bat)'
}

# =========================================================
#  4. 建桌面捷徑
# =========================================================
W-Step '在桌面建立「主機共用」捷徑'

$desktop = [Environment]::GetFolderPath('Desktop')
$publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')

# 兩個桌面都建 (個人 + 公用),保證任何使用者登入都看得到
foreach ($d in @($desktop, $publicDesktop)) {
    if (-not (Test-Path $d)) { continue }
    $lnkPath = Join-Path $d '主機共用.lnk'
    try {
        $wsh = New-Object -ComObject WScript.Shell
        $lnk = $wsh.CreateShortcut($lnkPath)
        $lnk.TargetPath = $share
        $lnk.IconLocation = 'imageres.dll,154'   # 網路資料夾圖示
        $lnk.Description = "主機共用資料夾 $share"
        $lnk.Save()
        W-OK "捷徑: $lnkPath -> $share"
    } catch {
        W-Warn "建立捷徑失敗 ($d): $($_.Exception.Message)"
    }
}

# =========================================================
#  5. (可選) 對應成磁碟機
# =========================================================
if ($MapDrive) {
    W-Step ("對應 $($DriveLetter): -> $share")
    try {
        & cmd /c "net use $($DriveLetter): /delete /y" 2>&1 | Out-Null
        $result = & cmd /c "net use $($DriveLetter): $share /persistent:yes" 2>&1
        if ($LASTEXITCODE -eq 0) {
            W-OK "$($DriveLetter): 對應成功"
        } else {
            W-Warn "對應失敗: $result"
        }
    } catch {
        W-Warn "對應例外: $($_.Exception.Message)"
    }
}

# =========================================================
#  6. 嘗試找 share 內的 VM_Share_Connect_v1.5.bat 自動跑
# =========================================================
if ($reachable) {
    $connectBat = Join-Path $share 'VM_Share_Connect_v1.5.bat'
    if (Test-Path $connectBat) {
        W-Step '偵測到 VM_Share_Connect_v1.5.bat,要不要跑?'
        $ans = Read-Host '(Y/N)'
        if ($ans -match '^[Yy]') {
            W-Info '執行 VM_Share_Connect_v1.5.bat...'
            Start-Process $connectBat -Verb RunAs -Wait
        }
    }
}

W-Title '完成'
Write-Host ''
Write-Host ' 之後使用:' -ForegroundColor White
Write-Host '   - 雙擊桌面「主機共用」即可開啟主機 share_folder' -ForegroundColor Gray
if ($MapDrive) {
    Write-Host "   - 或從 $($DriveLetter): 磁碟機直接存取" -ForegroundColor Gray
}
Write-Host ''
Write-Host ' 主機如果換 IP,只要主機名沒變,捷徑自動跟著走' -ForegroundColor Gray
Write-Host ' (Hyper-V KVP 一直提供當前主機名)' -ForegroundColor Gray
Write-Host ''
