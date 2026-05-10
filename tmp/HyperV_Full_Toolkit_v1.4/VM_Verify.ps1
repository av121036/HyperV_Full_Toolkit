# =========================================================
#  VM_Verify.ps1  -  VM 內部偽裝狀態驗證
#  在 VM 裡面執行(不需要系統管理員也可讀取大部分資訊)
# =========================================================

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
function W-Section($t) {
    Write-Host ''
    Write-Host ('[' + $t + ']') -ForegroundColor Magenta
}
function W-Row($label, $value, [ConsoleColor]$c = 'White') {
    Write-Host ('    {0,-18}: ' -f $label) -NoNewline -ForegroundColor Yellow
    Write-Host "$value" -ForegroundColor $c
}

W-Title 'VM 偽裝狀態驗證 v1.0'

# --- 電腦識別 ---
W-Section '電腦識別'
W-Row '電腦名稱' $env:COMPUTERNAME
try {
    $g = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop).MachineGuid
    W-Row 'MachineGuid' $g
} catch { W-Row 'MachineGuid' '讀取失敗' Red }

try {
    $prodId = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductId -ErrorAction Stop).ProductId
    W-Row 'ProductId' $prodId
} catch {}

try {
    $osName = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName -ErrorAction Stop).ProductName
    W-Row '作業系統' $osName
} catch {}

# --- BIOS / 主機板 登錄檔 ---
W-Section 'BIOS / 主機板 (登錄檔)'
$biosPath = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
try {
    $b = Get-ItemProperty -Path $biosPath -ErrorAction Stop
    W-Row '系統廠商'    $b.SystemManufacturer
    W-Row '系統型號'    $b.SystemProductName
    W-Row '系統族系'    $b.SystemFamily
    W-Row '系統 SKU'    $b.SystemSKU
    W-Row '系統序號'    $b.SystemSerialNumber
    W-Row '主機板廠商'  $b.BaseBoardManufacturer
    W-Row '主機板型號'  $b.BaseBoardProduct
    W-Row '主機板序號'  $b.BaseBoardSerialNumber
    W-Row 'BIOS 廠商'   $b.BIOSVendor
    W-Row 'BIOS 版本'   $b.BIOSVersion
    W-Row 'BIOS 發行日' $b.BIOSReleaseDate
    W-Row '機箱序號'    $b.ChassisSerialNumber
} catch { Write-Host '    讀取失敗' -ForegroundColor Red }

# --- WMI 實際查詢結果(遊戲/外掛偵測會讀這個) ---
W-Section 'WMI 查詢 (實際被看到的值)'
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    W-Row 'Win32_CS 廠商'   $cs.Manufacturer
    W-Row 'Win32_CS 型號'   $cs.Model
    $hvp = $cs.HypervisorPresent
    $hvColor = if ($hvp) { 'Red' } else { 'Green' }
    $hvFlag  = if ($hvp) { 'True  (偵測到 Hypervisor!)' } else { 'False (OK)' }
    W-Row 'HypervisorPresent' $hvFlag $hvColor
} catch {}
try {
    $bw = Get-CimInstance Win32_BIOS
    W-Row 'Win32_BIOS 廠商' $bw.Manufacturer
    W-Row 'Win32_BIOS 版本' ($bw.SMBIOSBIOSVersion)
    W-Row 'Win32_BIOS 序號' $bw.SerialNumber
} catch {}
try {
    $bb = Get-CimInstance Win32_BaseBoard
    W-Row 'BaseBoard 廠商' $bb.Manufacturer
    W-Row 'BaseBoard 型號' $bb.Product
    W-Row 'BaseBoard 序號' $bb.SerialNumber
} catch {}
try {
    $enc = Get-CimInstance Win32_SystemEnclosure
    W-Row '機箱序號'       $enc.SerialNumber
} catch {}

# --- 網路卡 ---
W-Section '網路卡'
try {
    Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
        W-Row $_.Name ("$($_.MacAddress)   ($($_.LinkSpeed))")
    }
} catch {
    Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.MACAddress -and $_.NetEnabled } | ForEach-Object {
        W-Row $_.Name $_.MACAddress
    }
}

# --- 硬碟 ---
W-Section '硬碟 (Model + Serial)'
try {
    Get-CimInstance Win32_DiskDrive | ForEach-Object {
        $model = $_.Model
        $flag = if ($model -match 'Virtual|Msft|VMware|VirtualBox') { ' (虛擬)' } else { '' }
        W-Row $model ("$($_.SerialNumber)$flag")
    }
} catch {}

# --- CPU ---
W-Section 'CPU'
try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    W-Row 'CPU 名稱'   $cpu.Name
    W-Row 'CPU ID'     $cpu.ProcessorId
    W-Row '核心 / 執行緒' ("$($cpu.NumberOfCores) / $($cpu.NumberOfLogicalProcessors)")
} catch {}

# --- 顯示卡 ---
W-Section '顯示卡'
try {
    Get-CimInstance Win32_VideoController | ForEach-Object {
        W-Row $_.Name ("Driver: $($_.DriverVersion)")
    }
} catch {}

# --- 風險摘要 ---
W-Section '風險摘要 (會被偵測為虛擬的線索)'
$issues = @()
try {
    $cs = Get-CimInstance Win32_ComputerSystem
    if ($cs.HypervisorPresent) { $issues += 'HypervisorPresent=True' }
    if ($cs.Model -match 'Virtual') { $issues += 'Win32_CS Model 含 Virtual' }
    if ($cs.Manufacturer -match 'Microsoft Corporation') { $issues += 'Win32_CS 廠商=Microsoft(VM 預設值)' }
} catch {}
try {
    $bw = Get-CimInstance Win32_BIOS
    if ($bw.Manufacturer -match 'American Megatrends|Dell|ASUS|MSI|Gigabyte|ASRock') { } else {
        if ($bw.Manufacturer -match 'Microsoft') { $issues += "Win32_BIOS 廠商=$($bw.Manufacturer) (VM 預設值)" }
    }
} catch {}
try {
    Get-CimInstance Win32_DiskDrive | ForEach-Object {
        if ($_.Model -match 'Virtual|Msft') { $issues += "硬碟型號: $($_.Model)" }
    }
} catch {}

if ($issues.Count -eq 0) {
    Write-Host '    [+] 未偵測到明顯虛擬化特徵' -ForegroundColor Green
} else {
    foreach ($i in $issues) { Write-Host "    [!] $i" -ForegroundColor Red }
}

W-Title '驗證完成'
Write-Host ''
