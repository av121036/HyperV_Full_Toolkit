# =========================================================
#  VM_Camo_Restore_v1.0.ps1  -  VM_Camo 偽裝還原工具
#  用途: 還原被 VM_Camo_v1.4.ps1 修改的設定
#  使用: 以「系統管理員」身分執行 PowerShell,然後跑這支腳本
#        powershell -ExecutionPolicy Bypass -File .\VM_Camo_Restore_v1.0.ps1
# =========================================================

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

function W-Title($t) {
    Write-Host ''
    Write-Host ('=' * 56) -ForegroundColor Cyan
    Write-Host (" $t") -ForegroundColor Cyan
    Write-Host ('=' * 56) -ForegroundColor Cyan
}
function W-Step($t) { Write-Host "[*] $t" -ForegroundColor Yellow }
function W-OK($t)   { Write-Host "[+] $t" -ForegroundColor Green }
function W-Err($t)  { Write-Host "[X] $t" -ForegroundColor Red }
function W-Info($t) { Write-Host "    $t" -ForegroundColor Gray }
function W-Skip($t) { Write-Host "[-] $t" -ForegroundColor DarkGray }

# --- 檢查管理員權限 ---
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()`
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    W-Err '請以「系統管理員」身分執行 PowerShell 後再跑此腳本'
    Write-Host '   方法: 開始 → 搜尋 PowerShell → 右鍵「以系統管理員身分執行」' -ForegroundColor Yellow
    Read-Host '按 Enter 結束'
    exit 1
}

W-Title 'VM_Camo 還原工具 v1.0'

Write-Host ''
Write-Host '此工具會做:' -ForegroundColor White
Write-Host '  1. 移除開機自動套用偽裝的排程 (VM_Camo_BootApply)'
Write-Host '  2. 刪除 C:\ProgramData\VM_Camo\ 資料夾'
Write-Host '  3. 清除 HKLM\HARDWARE\DESCRIPTION\System\BIOS 偽造鍵值'
Write-Host '  4. 清除 HKLM\...\SystemInformation 偽造鍵值'
Write-Host '  5. 重新生成 MachineGuid (原值無法救回,只能換新)'
Write-Host '  6. 提示電腦名稱改回去 (需你提供原名)'
Write-Host ''
Write-Host '注意: BIOS 鍵值清除後,需重開機讓 Windows 從真實 BIOS 重建' -ForegroundColor Yellow
Write-Host ''
$go = Read-Host '確定開始還原嗎? (Y/N)'
if ($go -notmatch '^[Yy]') {
    Write-Host '已取消'
    exit 0
}

# =========================================================
# 1. 移除排程
# =========================================================
W-Step '步驟 1/6: 移除開機排程 VM_Camo_BootApply'
try {
    $task = Get-ScheduledTask -TaskName 'VM_Camo_BootApply' -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName 'VM_Camo_BootApply' -Confirm:$false -ErrorAction Stop
        W-OK '排程已移除 (VM_Camo_BootApply)'
    } else {
        W-Skip '排程不存在,跳過'
    }
} catch {
    W-Err ('移除排程失敗: ' + $_.Exception.Message)
}

# =========================================================
# 2. 刪除 VM_Camo 資料夾
# =========================================================
W-Step '步驟 2/6: 刪除 C:\ProgramData\VM_Camo\'
$camoFolder = 'C:\ProgramData\VM_Camo'
try {
    if (Test-Path $camoFolder) {
        Remove-Item -Path $camoFolder -Recurse -Force -ErrorAction Stop
        W-OK '資料夾已刪除'
    } else {
        W-Skip '資料夾不存在,跳過'
    }
} catch {
    W-Err ('刪除資料夾失敗: ' + $_.Exception.Message)
}

# =========================================================
# 3. 清除偽造的 BIOS 登錄檔鍵值
# =========================================================
W-Step '步驟 3/6: 清除偽造 BIOS 登錄檔'
$biosPath = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
$biosKeys = @(
    'SystemManufacturer','SystemProductName','SystemFamily','SystemSKU',
    'SystemVersion','SystemSerialNumber',
    'BaseBoardManufacturer','BaseBoardProduct','BaseBoardVersion','BaseBoardSerialNumber',
    'BIOSVendor','BIOSVersion','BIOSReleaseDate',
    'ChassisSerialNumber','EnclosureType'
)
$biosRemoved = 0
foreach ($k in $biosKeys) {
    try {
        $exists = Get-ItemProperty -Path $biosPath -Name $k -ErrorAction SilentlyContinue
        if ($null -ne $exists) {
            Remove-ItemProperty -Path $biosPath -Name $k -ErrorAction Stop
            W-Info ("清除: $k")
            $biosRemoved++
        }
    } catch {
        W-Err ("$k 清除失敗: " + $_.Exception.Message)
    }
}
W-OK ("BIOS 鍵值已清除: $biosRemoved 個 (重開機後 Windows 會自動從真實 BIOS 重建)")

# =========================================================
# 4. 清除 SystemInformation 偽造鍵值
# =========================================================
W-Step '步驟 4/6: 清除 SystemInformation 偽造鍵值'
$sysInfoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemInformation'
$sysKeys = @('BIOSVendor','BIOSVersion','SystemManufacturer','SystemProductName','SystemSKU')
$sysRemoved = 0
if (Test-Path $sysInfoPath) {
    foreach ($k in $sysKeys) {
        try {
            $exists = Get-ItemProperty -Path $sysInfoPath -Name $k -ErrorAction SilentlyContinue
            if ($null -ne $exists) {
                Remove-ItemProperty -Path $sysInfoPath -Name $k -ErrorAction Stop
                W-Info ("清除: $k")
                $sysRemoved++
            }
        } catch {
            W-Err ("$k 清除失敗: " + $_.Exception.Message)
        }
    }
}
W-OK ("SystemInformation 已清除: $sysRemoved 個")

# =========================================================
# 5. 重新生成 MachineGuid
# =========================================================
W-Step '步驟 5/6: 重新生成 MachineGuid'
Write-Host '    注意: 原始 MachineGuid 已被腳本覆蓋,無法復原。' -ForegroundColor Yellow
Write-Host '    只能重新隨機產生一個新值 (跟廠商系統用的識別不同)。' -ForegroundColor Yellow
$re = Read-Host '    要重新產生嗎? (Y/N,預設 N 直接保留現值)'
if ($re -match '^[Yy]') {
    try {
        $newGuid = [guid]::NewGuid().ToString()
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' `
                         -Name 'MachineGuid' -Value $newGuid -ErrorAction Stop
        W-OK ('新 MachineGuid = ' + $newGuid)
    } catch {
        W-Err ('生成失敗: ' + $_.Exception.Message)
    }
} else {
    W-Skip '保留目前 MachineGuid'
}

# =========================================================
# 6. 電腦名稱
# =========================================================
W-Step '步驟 6/6: 還原電腦名稱'
$currentName = $env:COMPUTERNAME
Write-Host ('    目前電腦名稱: ' + $currentName) -ForegroundColor White
Write-Host '    腳本把名稱改成 DESKTOP-xxx / PC-xxx / WIN-xxx / HOME-xxx / USER-xxx 的格式。' -ForegroundColor Gray
Write-Host '    若你記得原始名稱,請輸入 (留空跳過):' -ForegroundColor Gray
$origName = Read-Host '    原始電腦名稱'
if (-not [string]::IsNullOrWhiteSpace($origName)) {
    try {
        Rename-Computer -NewName $origName.Trim() -Force -ErrorAction Stop
        W-OK ('電腦名稱已設為: ' + $origName.Trim() + ' (重開機後生效)')
    } catch {
        W-Err ('改名失敗: ' + $_.Exception.Message)
    }
} else {
    W-Skip '已跳過電腦名稱還原'
    W-Info '可手動到「設定 → 系統 → 關於 → 重新命名此電腦」修改'
}

# =========================================================
# 總結
# =========================================================
W-Title '還原完成'
Write-Host ''
Write-Host ' 接下來:' -ForegroundColor Yellow
Write-Host '   1. 重新開機,讓 BIOS 登錄檔由 Windows 從真實 SMBIOS 重建'
Write-Host '   2. 重開機後可以打開 cmd 跑 systeminfo 確認廠牌資訊已恢復'
Write-Host '   3. 排程 VM_Camo_BootApply 已移除,不會再被套回去'
Write-Host ''
Write-Host ' 提醒: 此腳本沒有動到 MAC、磁碟序號、EFI/SMBIOS,' -ForegroundColor Gray
Write-Host '       因為 VM_Camo 本來就沒改這些 (你看那支腳本最後的提醒就知道)' -ForegroundColor Gray
Write-Host ''
$rb = Read-Host '要立即重新開機嗎? (Y/N)'
if ($rb -match '^[Yy]') {
    W-Step '10 秒後重新開機...按 Ctrl+C 取消'
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}
