# =========================================================
#  VM_Camo.ps1  -  VM 內部偽裝修改
#  在 VM 裡面以系統管理員身分執行
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

function New-RandomSerial([int]$len = 12) {
    $chars = [char[]]('ABCDEFGHJKLMNPQRSTUVWXYZ23456789')
    -join (1..$len | ForEach-Object { $chars[(Get-Random -Max $chars.Length)] })
}
function New-BiosDate {
    $d = (Get-Date).AddDays(-(Get-Random -Minimum 180 -Maximum 900))
    '{0:MM/dd/yyyy}' -f $d
}

W-Title 'VM 內部偽裝工具 v1.3 (整合 GPU 喚醒)'

# --- 品牌預設檔 ---
$brands = [ordered]@{
    '1' = @{
        Name                  = 'ASUS ROG STRIX'
        SystemManufacturer    = 'ASUSTeK COMPUTER INC.'
        SystemProductName     = 'ROG STRIX B660-A GAMING WIFI'
        SystemFamily          = 'ROG'
        SystemSKU             = 'SKU'
        BaseBoardManufacturer = 'ASUSTeK COMPUTER INC.'
        BaseBoardProduct      = 'ROG STRIX B660-A GAMING WIFI'
        BaseBoardVersion      = 'Rev 1.xx'
        BIOSVendor            = 'American Megatrends Inc.'
        BIOSVersion           = '2801'
    }
    '2' = @{
        Name                  = 'GIGABYTE AORUS'
        SystemManufacturer    = 'Gigabyte Technology Co., Ltd.'
        SystemProductName     = 'B650 AORUS ELITE AX'
        SystemFamily          = 'AORUS'
        SystemSKU             = 'Default string'
        BaseBoardManufacturer = 'Gigabyte Technology Co., Ltd.'
        BaseBoardProduct      = 'B650 AORUS ELITE AX'
        BaseBoardVersion      = 'x.x'
        BIOSVendor            = 'American Megatrends International, LLC.'
        BIOSVersion           = 'F20'
    }
    '3' = @{
        Name                  = 'MSI MAG'
        SystemManufacturer    = 'Micro-Star International Co., Ltd.'
        SystemProductName     = 'MAG B650 TOMAHAWK WIFI (MS-7D75)'
        SystemFamily          = 'MAG'
        SystemSKU             = 'Default string'
        BaseBoardManufacturer = 'Micro-Star International Co., Ltd.'
        BaseBoardProduct      = 'MAG B650 TOMAHAWK WIFI (MS-7D75)'
        BaseBoardVersion      = '1.0'
        BIOSVendor            = 'American Megatrends International, LLC.'
        BIOSVersion           = 'A.70'
    }
    '4' = @{
        Name                  = 'ASRock Steel Legend'
        SystemManufacturer    = 'ASRock'
        SystemProductName     = 'B650 Steel Legend WiFi'
        SystemFamily          = 'Steel Legend'
        SystemSKU             = 'Default string'
        BaseBoardManufacturer = 'ASRock'
        BaseBoardProduct      = 'B650 Steel Legend WiFi'
        BaseBoardVersion      = '1.0'
        BIOSVendor            = 'American Megatrends International, LLC.'
        BIOSVersion           = '3.10'
    }
    '5' = @{
        Name                  = 'Dell OptiPlex 7090'
        SystemManufacturer    = 'Dell Inc.'
        SystemProductName     = 'OptiPlex 7090 Tower'
        SystemFamily          = 'OptiPlex'
        SystemSKU             = 'OptiPlex 7090'
        BaseBoardManufacturer = 'Dell Inc.'
        BaseBoardProduct      = '0WMCV8'
        BaseBoardVersion      = 'A01'
        BIOSVendor            = 'Dell Inc.'
        BIOSVersion           = '2.8.1'
    }
}

# v1.2: 顯示目前 MAC OUI 提示,避免選錯品牌
Write-Host ''
Write-Host '--- MAC / 品牌對齊提示 ---' -ForegroundColor Cyan
try {
    $nic = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
    $macStr = $nic.MacAddress
    $ouiMap = @{ '04-D4-C4' = '[1] ASUS'; '1C-1B-0D' = '[2] GIGABYTE';
                 '00-D8-61' = '[3] MSI';  '70-85-C2' = '[4] ASRock';
                 '54-BF-64' = '[5] Dell' }
    $oui = if ($macStr.Length -ge 8) { $macStr.Substring(0, 8) } else { '' }
    Write-Host ('  目前網卡 MAC: ' + $macStr)
    if ($ouiMap.ContainsKey($oui)) {
        Write-Host ('  MAC 對應品牌: ' + $ouiMap[$oui] + ' <- 建議選這個對齊') -ForegroundColor Green
    } else {
        Write-Host ('  MAC OUI (' + $oui + ') 不在已知品牌列表 (可能還沒跑 Host_Camo)') -ForegroundColor Yellow
    }
} catch {
    Write-Host '  (讀取 MAC 失敗,可忽略此提示)' -ForegroundColor Gray
}

Write-Host ''
Write-Host '請選擇品牌偽裝檔:' -ForegroundColor White
foreach ($k in $brands.Keys) {
    Write-Host ('  [{0}] {1}' -f $k, $brands[$k].Name)
}
Write-Host '  [R] 隨機選擇' -ForegroundColor Cyan
Write-Host ''
$choice = Read-Host '請輸入選項'
if ($choice -match '^[Rr]$') {
    $choice = (Get-Random -Minimum 1 -Maximum 6).ToString()
    W-OK ('隨機選到:' + $brands[$choice].Name)
}
if (-not $brands.Contains($choice)) {
    W-Err '無效的選項'
    exit 1
}
$brand = $brands[$choice]
W-OK ('使用品牌:' + $brand.Name)
Write-Host ''

$report = [ordered]@{
    '品牌'         = $brand.Name
    'MachineGuid'  = '(未設定)'
    'ProductId'    = '(未設定)'
    '電腦名稱'     = '(未設定)'
    'BaseBoard SN' = '(未設定)'
}

# --- 1. MachineGuid ---
W-Step '修改 MachineGuid (HKLM\SOFTWARE\Microsoft\Cryptography)'
try {
    $newGuid = [guid]::NewGuid().ToString()
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' `
                     -Name 'MachineGuid' -Value $newGuid -ErrorAction Stop
    W-OK ('MachineGuid = ' + $newGuid)
    $report['MachineGuid'] = $newGuid
} catch { W-Err ('失敗:' + $_.Exception.Message) }

# --- 2. ProductId ---
W-Step '修改 Windows ProductId'
try {
    $newProductId = '{0:D5}-{1:D3}-{2:D7}-{3:D5}' -f `
        (Get-Random -Maximum 100000), (Get-Random -Maximum 1000), `
        (Get-Random -Maximum 10000000), (Get-Random -Maximum 100000)
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                     -Name 'ProductId' -Value $newProductId -ErrorAction Stop
    W-OK ('ProductId = ' + $newProductId)
    $report['ProductId'] = $newProductId
} catch { W-Err ('失敗:' + $_.Exception.Message) }

# --- 3. BIOS 登錄檔 ---
W-Step '修改 BIOS 偽裝登錄檔'
$biosPath = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
$serialNum    = New-RandomSerial 12
$baseBoardSN  = New-RandomSerial 12
$chassisSN    = New-RandomSerial 12
$report['BaseBoard SN'] = $baseBoardSN

$biosMap = [ordered]@{
    'SystemManufacturer'    = $brand.SystemManufacturer
    'SystemProductName'     = $brand.SystemProductName
    'SystemFamily'          = $brand.SystemFamily
    'SystemSKU'             = $brand.SystemSKU
    'SystemVersion'         = 'System Version'
    'SystemSerialNumber'    = $serialNum
    'BaseBoardManufacturer' = $brand.BaseBoardManufacturer
    'BaseBoardProduct'      = $brand.BaseBoardProduct
    'BaseBoardVersion'      = $brand.BaseBoardVersion
    'BaseBoardSerialNumber' = $baseBoardSN
    'BIOSVendor'            = $brand.BIOSVendor
    'BIOSVersion'           = $brand.BIOSVersion
    'BIOSReleaseDate'       = (New-BiosDate)
    'ChassisSerialNumber'   = $chassisSN
    'EnclosureType'         = 3
}
foreach ($k in $biosMap.Keys) {
    try {
        $v = $biosMap[$k]
        if ($v -is [int]) {
            New-ItemProperty -Path $biosPath -Name $k -Value $v -PropertyType DWord -Force | Out-Null
        } else {
            New-ItemProperty -Path $biosPath -Name $k -Value $v -PropertyType String -Force | Out-Null
        }
        W-Info ("{0,-22} = {1}" -f $k, $v)
    } catch {
        W-Err ($k + ' 失敗:' + $_.Exception.Message)
    }
}

# --- 4. SystemInformation (某些應用會讀這裡) ---
W-Step '同步更新 SystemInformation 登錄檔'
$sysInfoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemInformation'
try {
    if (-not (Test-Path $sysInfoPath)) { New-Item -Path $sysInfoPath -Force | Out-Null }
    $sysInfoMap = @{
        'BIOSVendor'         = $brand.BIOSVendor
        'BIOSVersion'        = $brand.BIOSVersion
        'SystemManufacturer' = $brand.SystemManufacturer
        'SystemProductName'  = $brand.SystemProductName
        'SystemSKU'          = $brand.SystemSKU
    }
    foreach ($k in $sysInfoMap.Keys) {
        New-ItemProperty -Path $sysInfoPath -Name $k -Value $sysInfoMap[$k] `
                         -PropertyType String -Force | Out-Null
    }
    W-OK 'SystemInformation 已更新'
} catch { W-Err ('失敗:' + $_.Exception.Message) }

# --- 5. 產生新電腦名稱 ---
W-Step '變更電腦名稱'
$prefixes = @('DESKTOP', 'PC', 'WIN', 'HOME', 'USER')
$prefix   = $prefixes[(Get-Random -Max $prefixes.Length)]
$suffix   = -join ((48..57) + (65..90) | Get-Random -Count 7 | ForEach-Object { [char]$_ })
$newName  = "$prefix-$suffix"
try {
    Rename-Computer -NewName $newName -Force -ErrorAction Stop
    W-OK ('電腦名稱 = ' + $newName + '  (重開機後生效)')
    $report['電腦名稱'] = "$newName (重開生效)"
} catch {
    W-Err ('失敗:' + $_.Exception.Message)
}

# --- 6. 建立開機自動重套用的排程 (解決 HARDWARE hive 被重建的問題) ---
W-Step '建立開機自動重套用排程'
Write-Host '    BIOS 登錄檔會在每次開機被系統重建,' -ForegroundColor Gray
Write-Host '    建議建立「開機重套用」排程讓偽裝持續生效。' -ForegroundColor Gray
$taskYn = Read-Host '要建立嗎?(Y/N,強烈建議 Y)'

if ($taskYn -match '^[Yy]') {
    try {
        $taskFolder = 'C:\ProgramData\VM_Camo'
        if (-not (Test-Path $taskFolder)) {
            New-Item -Path $taskFolder -ItemType Directory -Force | Out-Null
        }

        # 儲存品牌資料
        $profileData = @{
            Brand    = $brand
            BiosMap  = $biosMap
            SysInfo  = $sysInfoMap
            SavedAt  = (Get-Date).ToString('o')
        }
        $profileData | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $taskFolder 'profile.json') -Encoding UTF8

        # 寫入開機套用腳本
        $bootScript = @'
# VM_Camo boot reapply - auto-generated
try {
    $p = Get-Content 'C:\ProgramData\VM_Camo\profile.json' -Raw | ConvertFrom-Json
    $biosPath = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'

    # BIOS 主鍵可能剛開機還沒建立,等一下
    $retry = 0
    while (-not (Test-Path $biosPath) -and $retry -lt 10) {
        Start-Sleep -Seconds 2
        $retry++
    }

    foreach ($prop in $p.BiosMap.PSObject.Properties) {
        $v = $prop.Value
        if ($v -is [int] -or $v -is [long]) {
            New-ItemProperty -Path $biosPath -Name $prop.Name -Value $v -PropertyType DWord -Force | Out-Null
        } else {
            New-ItemProperty -Path $biosPath -Name $prop.Name -Value "$v" -PropertyType String -Force | Out-Null
        }
    }

    $sysInfoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemInformation'
    if (-not (Test-Path $sysInfoPath)) { New-Item -Path $sysInfoPath -Force | Out-Null }
    foreach ($prop in $p.SysInfo.PSObject.Properties) {
        New-ItemProperty -Path $sysInfoPath -Name $prop.Name -Value "$($prop.Value)" -PropertyType String -Force | Out-Null
    }

    Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] OK - {1}" -f (Get-Date), $p.Brand.Name)
} catch {
    Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] ERR - {1}" -f (Get-Date), $_.Exception.Message)
}

# --- GPU 喚醒 (解決 Cannot Open OpenGL) ---
try {
    # 等桌面載入完成再跑,避免排程太早跑沒作用
    Start-Sleep -Seconds 15

    # 檢查 GPU-PV 是否已正常掛載 (有 NVIDIA 才喚醒,內顯不用)
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX' } |
           Select-Object -First 1

    if ($gpu) {
        # 開 dxdiag 觸發 GPU 資源重新偵測,5 秒後自動關閉 (使用者無感)
        Start-Process -FilePath 'dxdiag.exe' -ArgumentList '/whql:off' -WindowStyle Hidden
        Start-Sleep -Seconds 5
        Stop-Process -Name 'dxdiag' -Force -ErrorAction SilentlyContinue
        Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] GPU Wake OK - {1}" -f (Get-Date), $gpu.Name)
    } else {
        Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] GPU Wake Skip - No NVIDIA GPU detected" -f (Get-Date))
    }
} catch {
    Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] GPU Wake ERR - {1}" -f (Get-Date), $_.Exception.Message)
}
'@
        $bootScriptPath = Join-Path $taskFolder 'Apply_Boot.ps1'
        Set-Content -Path $bootScriptPath -Value $bootScript -Encoding UTF8

        # 註冊開機排程
        $taskName = 'VM_Camo_BootApply'
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootScriptPath`""
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                              -Principal $principal -Settings $settings `
                              -Description 'VM Camouflage - reapply BIOS registry after boot' `
                              -Force | Out-Null

        W-OK ('排程已建立:' + $taskName)
        W-Info ("腳本路徑: " + $bootScriptPath)
        W-Info ("設定檔  : " + (Join-Path $taskFolder 'profile.json'))
        W-Info '開機後約 10 秒內會自動套用 BIOS 偽裝'
        W-Info '開機後約 20 秒內會自動喚醒 GPU (解決 Cannot Open OpenGL)'
    } catch {
        W-Err ('排程建立失敗:' + $_.Exception.Message)
    }
} else {
    W-Info '已跳過。注意:重開機後 BIOS 偽裝會失效,需手動再跑一次本工具。'
}

# --- 7. 總結 ---
W-Title '偽裝修改完成'
foreach ($k in $report.Keys) {
    Write-Host ('    {0,-14}: {1}' -f $k, $report[$k]) -ForegroundColor White
}

Write-Host ''
Write-Host ' 重要提醒:' -ForegroundColor Yellow
Write-Host '   1. 電腦名稱需重新開機才會生效'
Write-Host '   2. Volume Serial(磁碟區序號)需用 VolumeID.exe 另行修改'
Write-Host '   3. MAC 位址需在主機端 Hyper-V 修改(執行 Host_Camo.bat)'
Write-Host '   4. 建議接著執行 VM_Verify.bat 檢查結果'
Write-Host ''

$rb = Read-Host '要立即重新開機讓設定生效嗎?(Y/N)'
if ($rb -match '^[Yy]') {
    W-Step '10 秒後重新開機...按 Ctrl+C 取消'
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}
