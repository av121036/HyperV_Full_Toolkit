# =========================================================
#  Host_Camo_v1.1.ps1  -  Hyper-V 主機端 VM 偽裝工具
#  v1.1:
#    - 加入「5 秒倒數預設值」機制,Enter 或不動立即套用預設
#    - VM 選擇仍需手動 (避免挑錯台)
#    - 品牌預設「隨機」,Enter 直接隨機
#    - 關機 / 啟動預設 Y
# =========================================================

$ErrorActionPreference = 'Stop'
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

# =========================================================
#  通用:倒數預設值輸入  (5 秒內沒動就用預設)
#  - Enter           -> 立即套用預設
#  - 5 秒沒動        -> 自動套用預設
#  - 打字            -> 切回正常輸入,讀完整一行
# =========================================================
function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default,
        [int]$Seconds = 5
    )
    $promptText = "$Prompt [預設=$Default,${Seconds}秒後自動套用]: "
    Write-Host $promptText -ForegroundColor White -NoNewline

    # 清掉殘留按鍵
    while ($Host.UI.RawUI.KeyAvailable) { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.VirtualKeyCode -eq 13) {
                # Enter
                Write-Host ('(預設) ' + $Default) -ForegroundColor DarkGray
                return $Default
            } else {
                # 其他按鍵 -> 切回正常輸入,把那個字元當作開頭
                $first = $key.Character
                Write-Host -NoNewline $first
                $rest = [Console]::ReadLine()
                $full = "$first$rest"
                if ([string]::IsNullOrWhiteSpace($full)) { return $Default }
                return $full.Trim()
            }
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ('(超時) ' + $Default) -ForegroundColor DarkGray
    return $Default
}

W-Title '主機端 VM 偽裝工具 v1.1'

# --- 檢查 Hyper-V 模組 ---
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    W-Err '找不到 Hyper-V PowerShell 模組'
    W-Info '請確認:這台電腦是 Hyper-V 主機,且已安裝 Hyper-V 管理工具'
    exit 1
}
Import-Module Hyper-V -ErrorAction SilentlyContinue

# --- 列出所有 VM (一定要手動選) ---
$vms = @(Get-VM | Sort-Object Name)
if ($vms.Count -eq 0) {
    W-Err '找不到任何 VM'
    exit 1
}

Write-Host ''
Write-Host '可用的 VM:' -ForegroundColor White
for ($i = 0; $i -lt $vms.Count; $i++) {
    $v = $vms[$i]
    $stateColor = if ($v.State -eq 'Running') {'Green'} else {'Gray'}
    Write-Host ('  [{0}] {1,-30} ({2})' -f ($i + 1), $v.Name, $v.State) -ForegroundColor $stateColor
}
Write-Host ''
$raw = Read-Host '請輸入 VM 編號 (此項無預設,必須手動選)'
if (-not ($raw -as [int]) -or [int]$raw -lt 1 -or [int]$raw -gt $vms.Count) {
    W-Err '無效的編號'
    exit 1
}
$vm = $vms[[int]$raw - 1]
W-OK ('已選擇:' + $vm.Name)

# --- 品牌 MAC OUI 對應 ---
$brands = [ordered]@{
    '1' = @{ Name='ASUS';     OUI='04-D4-C4'; Raw='04D4C4' }
    '2' = @{ Name='GIGABYTE'; OUI='1C-1B-0D'; Raw='1C1B0D' }
    '3' = @{ Name='MSI';      OUI='00-D8-61'; Raw='00D861' }
    '4' = @{ Name='ASRock';   OUI='70-85-C2'; Raw='7085C2' }
    '5' = @{ Name='Dell';     OUI='54-BF-64'; Raw='54BF64' }
}

Write-Host ''
Write-Host '請選擇品牌 MAC 前綴:' -ForegroundColor White
foreach ($k in $brands.Keys) {
    Write-Host ('  [{0}] {1,-10} ({2})' -f $k, $brands[$k].Name, $brands[$k].OUI)
}
Write-Host '  [R] 隨機選一個品牌  <-- 預設' -ForegroundColor Cyan
Write-Host ''
$bc = Read-WithDefault -Prompt '請輸入選項 (1-5 / R)' -Default 'R' -Seconds 5
if ($bc -match '^[Rr]$') {
    $bc = (Get-Random -Minimum 1 -Maximum 6).ToString()
    W-OK ('隨機選擇:' + $brands[$bc].Name)
}
if (-not $brands.Contains($bc)) {
    W-Err '無效的選項'
    exit 1
}
$brand = $brands[$bc]

# --- 寫入「最後使用品牌」給 VM_Camo 對齊參考(寫在 VM 下次能讀到的地方:暫存到本機) ---
# VM 主要靠 MAC OUI 偵測,這個檔案僅供主機端記錄
try {
    $stateDir = 'C:\ProgramData\VM_Camo'
    if (-not (Test-Path $stateDir)) { New-Item -Path $stateDir -ItemType Directory -Force | Out-Null }
    @{ LastBrand = $brand.Name; LastOui = $brand.OUI; SavedAt = (Get-Date).ToString('o') } |
        ConvertTo-Json | Set-Content -Path (Join-Path $stateDir 'host_last_brand.json') -Encoding UTF8
} catch {}

# --- 產生隨機 MAC 尾段(3 bytes) ---
$tail = -join (1..6 | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) })
$macRaw = $brand.Raw + $tail
$macFormatted = ($macRaw -replace '(.{2})(?!$)', '$1-')
W-Info ('預計設定 MAC: ' + $macFormatted)

# --- 如果 VM 在運作,詢問是否關機 (預設 Y) ---
$wasRunning = $false
if ($vm.State -eq 'Running') {
    Write-Host ''
    Write-Host '[!] VM 目前在運作中,修改 MAC 必須先關機。' -ForegroundColor Yellow
    $yn = Read-WithDefault -Prompt '要立即關機嗎? (Y/N)' -Default 'Y' -Seconds 5
    if ($yn -match '^[Yy]') {
        W-Step ('關閉 ' + $vm.Name + ' ...')
        try {
            Stop-VM -Name $vm.Name -Force -ErrorAction Stop
            W-OK '已關機'
            $wasRunning = $true
        } catch {
            W-Err ('關機失敗:' + $_.Exception.Message)
            exit 1
        }
    } else {
        W-Err '取消操作'
        exit 1
    }
}

# --- 設定靜態 MAC ---
W-Step '設定靜態 MAC 位址'
try {
    Get-VMNetworkAdapter -VMName $vm.Name | Set-VMNetworkAdapter -StaticMacAddress $macRaw -ErrorAction Stop
    W-OK ('MAC 已設為 ' + $macFormatted)
} catch {
    W-Err ('MAC 設定失敗:' + $_.Exception.Message)
}

# --- 修改 BIOS GUID 與 BaseBoardSerial(透過 WMI) ---
W-Step '修改 BIOS GUID 與 BaseBoard 序號'
try {
    $vsms = Get-WmiObject -Namespace 'root\virtualization\v2' `
                          -Class 'Msvm_VirtualSystemManagementService'
    $vmObj = Get-WmiObject -Namespace 'root\virtualization\v2' `
                           -Class 'Msvm_ComputerSystem' `
            | Where-Object { $_.ElementName -eq $vm.Name }
    $settings = Get-WmiObject -Namespace 'root\virtualization\v2' `
                              -Class 'Msvm_VirtualSystemSettingData' `
              | Where-Object { $_.ConfigurationID -eq $vmObj.Name -and $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }

    if ($settings) {
        $newBiosGuid = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
        $newBaseSerial = -join ((0..11) | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) })
        $newChassisSerial = -join ((0..11) | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) })

        $settings.BIOSGUID = $newBiosGuid
        if ($settings.PSObject.Properties['BaseBoardSerialNumber']) {
            $settings.BaseBoardSerialNumber = $newBaseSerial
        }
        if ($settings.PSObject.Properties['ChassisSerialNumber']) {
            $settings.ChassisSerialNumber = $newChassisSerial
        }

        $result = $vsms.ModifySystemSettings($settings.GetText(1))
        if ($result.ReturnValue -eq 0 -or $result.ReturnValue -eq 4096) {
            W-OK ('BIOS GUID: ' + $newBiosGuid)
            W-OK ('BaseBoard Serial: ' + $newBaseSerial)
            W-OK ('Chassis  Serial: ' + $newChassisSerial)
        } else {
            W-Err ('ModifySystemSettings 回傳值:' + $result.ReturnValue)
        }
    } else {
        W-Err '讀不到 VirtualSystemSettingData'
    }
} catch {
    W-Err ('BIOS GUID 修改失敗:' + $_.Exception.Message)
}

# --- 詢問是否啟動 VM (預設 Y) ---
Write-Host ''
$start = Read-WithDefault -Prompt '要立即啟動 VM 嗎? (Y/N)' -Default 'Y' -Seconds 5
if ($start -match '^[Yy]') {
    try {
        Start-VM -Name $vm.Name -ErrorAction Stop
        W-OK '已啟動'
    } catch {
        W-Err ('啟動失敗:' + $_.Exception.Message)
    }
} elseif ($wasRunning) {
    W-Info '提醒:VM 之前在運作中,你剛選擇不啟動。請記得後續手動啟動。'
}

W-Title '主機端偽裝完成'
Write-Host (' 本次品牌: ' + $brand.Name + '  MAC OUI: ' + $brand.OUI)
Write-Host ' 下一步:進入 VM 執行 VM_Camo_v1.4.bat 完成 VM 內偽裝'
Write-Host ' VM 端會自動依 MAC OUI 對齊到同一個品牌'
Write-Host ''
