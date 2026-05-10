# =========================================================
#  Host_Camo_v1.2.ps1  -  Hyper-V 主機端 VM 偽裝工具
#  v1.2:
#    - 批量處理:單一輸入框支援
#         單一數字   (1)
#         逗號清單   (1,3,5)
#         區間       (2-4)
#         混合       (1,3-5,7)
#         all        (全選)
#    - 每台 VM 獨立隨機品牌 (MAC OUI 各自不同)
#    - 運作中 VM 自動關機 (Enter 預設 Y)
#    - 跑完只重啟「原本運作中」的 VM
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
function W-Sub($t) {
    Write-Host ''
    Write-Host ('--- ' + $t + ' ---') -ForegroundColor Magenta
}
function W-Step($t) { Write-Host "[*] $t" -ForegroundColor Yellow }
function W-OK($t)   { Write-Host "[+] $t" -ForegroundColor Green }
function W-Err($t)  { Write-Host "[X] $t" -ForegroundColor Red }
function W-Info($t) { Write-Host "    $t" -ForegroundColor Gray }

# =========================================================
#  通用:倒數預設值輸入
# =========================================================
function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default,
        [int]$Seconds = 5
    )
    $promptText = "$Prompt [預設=$Default,${Seconds}秒後自動套用]: "
    Write-Host $promptText -ForegroundColor White -NoNewline

    while ($Host.UI.RawUI.KeyAvailable) { [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ($Host.UI.RawUI.KeyAvailable) {
            $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            if ($key.VirtualKeyCode -eq 13) {
                Write-Host ('(預設) ' + $Default) -ForegroundColor DarkGray
                return $Default
            } else {
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

# =========================================================
#  解析「批量選擇字串」-> 1-based 編號陣列
#  支援:1   1,3,5   2-4   1,3-5,7   all
# =========================================================
function Parse-Selection {
    param(
        [string]$Raw,
        [int]$Max
    )
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $Raw = $Raw.Trim()
    if ($Raw -match '^[Aa][Ll][Ll]$') { return 1..$Max }

    $set = New-Object System.Collections.Generic.SortedSet[int]
    $tokens = $Raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    foreach ($tk in $tokens) {
        if ($tk -match '^(\d+)\s*-\s*(\d+)$') {
            $a = [int]$matches[1]; $b = [int]$matches[2]
            if ($a -gt $b) { $tmp = $a; $a = $b; $b = $tmp }
            for ($i = $a; $i -le $b; $i++) {
                if ($i -ge 1 -and $i -le $Max) { [void]$set.Add($i) }
            }
        } elseif ($tk -match '^\d+$') {
            $n = [int]$tk
            if ($n -ge 1 -and $n -le $Max) { [void]$set.Add($n) }
        } else {
            throw "無法解析 token: $tk"
        }
    }
    return @($set)
}

W-Title '主機端 VM 偽裝工具 v1.2 (批量版)'

# --- 檢查 Hyper-V 模組 ---
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    W-Err '找不到 Hyper-V PowerShell 模組'
    W-Info '請確認:這台電腦是 Hyper-V 主機,且已安裝 Hyper-V 管理工具'
    exit 1
}
Import-Module Hyper-V -ErrorAction SilentlyContinue

# --- 列出所有 VM ---
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
    Write-Host ('  [{0,2}] {1,-30} ({2})' -f ($i + 1), $v.Name, $v.State) -ForegroundColor $stateColor
}
Write-Host ''
Write-Host '輸入格式範例:' -ForegroundColor Gray
Write-Host '  1            -> 單選' -ForegroundColor Gray
Write-Host '  1,3,5        -> 多選' -ForegroundColor Gray
Write-Host '  2-4          -> 區間' -ForegroundColor Gray
Write-Host '  1,3-5,7      -> 混合' -ForegroundColor Gray
Write-Host '  all          -> 全選' -ForegroundColor Gray
Write-Host ''

$raw = Read-Host '請輸入要處理的 VM 編號 (此項無預設,必須輸入)'
try {
    $selectedIdx = Parse-Selection -Raw $raw -Max $vms.Count
} catch {
    W-Err ('解析失敗: ' + $_.Exception.Message)
    exit 1
}

if ($selectedIdx.Count -eq 0) {
    W-Err '沒有選到任何 VM'
    exit 1
}

$selectedVms = @()
foreach ($i in $selectedIdx) { $selectedVms += $vms[$i - 1] }

W-OK ('已選擇 ' + $selectedVms.Count + ' 台 VM:')
foreach ($v in $selectedVms) {
    W-Info (' - ' + $v.Name + '  (' + $v.State + ')')
}

# --- 品牌 MAC OUI 對應 (5 個品牌) ---
$brands = [ordered]@{
    '1' = @{ Name='ASUS';     OUI='04-D4-C4'; Raw='04D4C4' }
    '2' = @{ Name='GIGABYTE'; OUI='1C-1B-0D'; Raw='1C1B0D' }
    '3' = @{ Name='MSI';      OUI='00-D8-61'; Raw='00D861' }
    '4' = @{ Name='ASRock';   OUI='70-85-C2'; Raw='7085C2' }
    '5' = @{ Name='Dell';     OUI='54-BF-64'; Raw='54BF64' }
}
$brandKeys = @($brands.Keys)

# --- 整批操作前的確認 (預設 Y) ---
Write-Host ''
W-Step '本次將執行的動作摘要'
W-Info ('VM 數量      : ' + $selectedVms.Count + ' 台')
W-Info '品牌分配     : 每台獨立隨機 (5 個品牌)'
W-Info '運作中 VM    : 自動關機 -> 改設定 -> 重新啟動 (其他保持關機)'
W-Info 'BIOS GUID    : 每台獨立隨機'
W-Info 'BaseBoard SN : 每台獨立隨機'
Write-Host ''
$go = Read-WithDefault -Prompt '確認開始批量處理? (Y/N)' -Default 'Y' -Seconds 5
if ($go -notmatch '^[Yy]') {
    W-Err '使用者取消'
    exit 0
}

# --- 紀錄器(用於最後總結) ---
$results = @()

# --- 主迴圈 ---
$counter = 0
foreach ($vm in $selectedVms) {
    $counter++
    W-Title ("[{0}/{1}] 處理: {2}" -f $counter, $selectedVms.Count, $vm.Name)

    $rec = [ordered]@{
        Name        = $vm.Name
        Brand       = ''
        MAC         = ''
        BiosGuid    = ''
        BaseSerial  = ''
        WasRunning  = ($vm.State -eq 'Running')
        Restarted   = $false
        Status      = 'OK'
        Note        = ''
    }

    # --- 獨立隨機品牌 ---
    $bk = $brandKeys[(Get-Random -Max $brandKeys.Count)]
    $brand = $brands[$bk]
    $rec.Brand = $brand.Name
    W-OK ('品牌(隨機): ' + $brand.Name + '  OUI=' + $brand.OUI)

    # --- 產生隨機 MAC 尾段(3 bytes) ---
    $tail = -join (1..6 | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) })
    $macRaw = $brand.Raw + $tail
    $macFormatted = ($macRaw -replace '(.{2})(?!$)', '$1-')
    $rec.MAC = $macFormatted
    W-Info ('預計 MAC : ' + $macFormatted)

    # --- 運作中 -> 自動關機 ---
    if ($vm.State -eq 'Running') {
        W-Step '關機中...'
        try {
            Stop-VM -Name $vm.Name -Force -ErrorAction Stop
            W-OK '已關機'
        } catch {
            W-Err ('關機失敗:' + $_.Exception.Message)
            $rec.Status = 'FAIL'
            $rec.Note   = '關機失敗,跳過此 VM'
            $results += [pscustomobject]$rec
            continue
        }
    }

    # --- 設定靜態 MAC ---
    W-Step '設定靜態 MAC 位址'
    try {
        Get-VMNetworkAdapter -VMName $vm.Name | Set-VMNetworkAdapter -StaticMacAddress $macRaw -ErrorAction Stop
        W-OK ('MAC 已設為 ' + $macFormatted)
    } catch {
        W-Err ('MAC 設定失敗:' + $_.Exception.Message)
        $rec.Status = 'PARTIAL'
        $rec.Note   = 'MAC 設定失敗'
    }

    # --- 修改 BIOS GUID 與 BaseBoardSerial(WMI) ---
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
            $newBiosGuid     = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
            $newBaseSerial   = -join ((0..11) | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) })
            $newChassisSerial= -join ((0..11) | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) })

            $settings.BIOSGUID = $newBiosGuid
            if ($settings.PSObject.Properties['BaseBoardSerialNumber']) {
                $settings.BaseBoardSerialNumber = $newBaseSerial
            }
            if ($settings.PSObject.Properties['ChassisSerialNumber']) {
                $settings.ChassisSerialNumber = $newChassisSerial
            }

            $result = $vsms.ModifySystemSettings($settings.GetText(1))
            if ($result.ReturnValue -eq 0 -or $result.ReturnValue -eq 4096) {
                W-OK ('BIOS GUID       : ' + $newBiosGuid)
                W-OK ('BaseBoard Serial: ' + $newBaseSerial)
                W-OK ('Chassis  Serial: ' + $newChassisSerial)
                $rec.BiosGuid   = $newBiosGuid
                $rec.BaseSerial = $newBaseSerial
            } else {
                W-Err ('ModifySystemSettings 回傳值:' + $result.ReturnValue)
                $rec.Status = 'PARTIAL'
                $rec.Note   = ($rec.Note + ' BIOS 修改失敗(回傳' + $result.ReturnValue + ')').Trim()
            }
        } else {
            W-Err '讀不到 VirtualSystemSettingData'
            $rec.Status = 'PARTIAL'
            $rec.Note   = ($rec.Note + ' 讀不到設定資料').Trim()
        }
    } catch {
        W-Err ('BIOS GUID 修改失敗:' + $_.Exception.Message)
        $rec.Status = 'PARTIAL'
        $rec.Note   = ($rec.Note + ' BIOS GUID 例外').Trim()
    }

    # --- 只重啟「原本就在跑」的 VM ---
    if ($rec.WasRunning) {
        W-Step '原本在運作中,重新啟動...'
        try {
            Start-VM -Name $vm.Name -ErrorAction Stop
            W-OK '已啟動'
            $rec.Restarted = $true
        } catch {
            W-Err ('啟動失敗:' + $_.Exception.Message)
            $rec.Note = ($rec.Note + ' 啟動失敗').Trim()
        }
    } else {
        W-Info '原本就是關機狀態,維持關機'
    }

    $results += [pscustomobject]$rec
}

# =========================================================
#  總結報表
# =========================================================
W-Title '批量處理完成 - 總結'

Write-Host ''
$fmt = '{0,-3} {1,-22} {2,-18} {3,-19} {4,-9} {5,-9} {6}'
Write-Host ($fmt -f '#', 'VM 名稱', '品牌', 'MAC', '原狀態', '已重啟', '狀態') -ForegroundColor White
Write-Host ('-' * 110) -ForegroundColor DarkGray

$idx = 0
foreach ($r in $results) {
    $idx++
    $color = switch ($r.Status) {
        'OK'      { 'Green' }
        'PARTIAL' { 'Yellow' }
        'FAIL'    { 'Red' }
        default   { 'Gray' }
    }
    $wasState = if ($r.WasRunning) { 'Running' } else { 'Off' }
    $reBool   = if ($r.Restarted)  { 'Yes' }     else { 'No' }
    Write-Host ($fmt -f $idx, $r.Name, $r.Brand, $r.MAC, $wasState, $reBool, $r.Status) -ForegroundColor $color
    if ($r.Note) {
        Write-Host ('     備註: ' + $r.Note) -ForegroundColor DarkGray
    }
}

# 統計
$ok      = ($results | Where-Object { $_.Status -eq 'OK' }).Count
$partial = ($results | Where-Object { $_.Status -eq 'PARTIAL' }).Count
$fail    = ($results | Where-Object { $_.Status -eq 'FAIL' }).Count

Write-Host ''
Write-Host ('  成功 : ' + $ok)      -ForegroundColor Green
Write-Host ('  部分 : ' + $partial) -ForegroundColor Yellow
Write-Host ('  失敗 : ' + $fail)    -ForegroundColor Red

# 匯出 CSV (方便對照)
try {
    $stateDir = 'C:\ProgramData\VM_Camo'
    if (-not (Test-Path $stateDir)) { New-Item -Path $stateDir -ItemType Directory -Force | Out-Null }
    $csvPath = Join-Path $stateDir ('host_camo_batch_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.csv')
    $results | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    Write-Host ''
    W-Info ('批次紀錄已匯出: ' + $csvPath)
} catch {}

Write-Host ''
Write-Host ' 下一步:在每台 VM 內各自執行 VM_Camo_v1.4.bat' -ForegroundColor White
Write-Host '         它會偵測 MAC OUI 自動對齊到對應品牌,Enter 一路按到底' -ForegroundColor White
Write-Host ''
