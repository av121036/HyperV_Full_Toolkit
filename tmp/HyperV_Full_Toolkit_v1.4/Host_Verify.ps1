# =========================================================
#  Host_Verify.ps1  -  Hyper-V 主機端 VM 狀態驗證
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
function W-Row($label, $value, [ConsoleColor]$c = 'White') {
    Write-Host ('    {0,-14}: ' -f $label) -NoNewline -ForegroundColor Yellow
    Write-Host "$value" -ForegroundColor $c
}

W-Title '主機端 VM 狀態驗證 v1.0'

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    Write-Host '[X] 找不到 Hyper-V 模組。這台電腦可能不是 Hyper-V 主機。' -ForegroundColor Red
    exit 1
}
Import-Module Hyper-V -ErrorAction SilentlyContinue

$vms = @(Get-VM | Sort-Object Name)
if ($vms.Count -eq 0) {
    Write-Host '[X] 找不到任何 VM' -ForegroundColor Red
    exit 1
}

# 快取一次 WMI VirtualSystemSettingData,避免每台 VM 都重跑
$allSettings = @{}
try {
    $list = Get-WmiObject -Namespace 'root\virtualization\v2' `
                          -Class 'Msvm_VirtualSystemSettingData' `
          | Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' }
    foreach ($s in $list) {
        $allSettings[$s.ConfigurationID] = $s
    }
} catch {}

$allVmObj = @{}
try {
    $list2 = Get-WmiObject -Namespace 'root\virtualization\v2' `
                           -Class 'Msvm_ComputerSystem' `
           | Where-Object { $_.Caption -eq 'Virtual Machine' }
    foreach ($o in $list2) { $allVmObj[$o.ElementName] = $o }
} catch {}

foreach ($vm in $vms) {
    Write-Host ''
    Write-Host ('--- ' + $vm.Name + ' ---') -ForegroundColor Magenta

    $stateColor = if ($vm.State -eq 'Running') {'Green'} else {'Gray'}
    W-Row '狀態'     $vm.State $stateColor
    W-Row '世代'     ('Generation ' + $vm.Generation)
    W-Row 'CPU 核心' ($vm.ProcessorCount.ToString() + ' 核')
    W-Row '記憶體'   ('{0:N0} MB' -f ($vm.MemoryStartup / 1MB))
    W-Row '安全開機' $vm.SecureBootEnabled

    # 網卡資訊
    $nics = Get-VMNetworkAdapter -VMName $vm.Name
    foreach ($n in $nics) {
        $macType = if ($n.DynamicMacAddressEnabled) { '動態 (危險)' } else { '靜態 (OK)' }
        $macFmt = if ($n.MacAddress -and $n.MacAddress -ne '000000000000') {
            ($n.MacAddress -replace '(.{2})(?!$)', '$1-')
        } else { '(未設定)' }
        W-Row '網路交換器' ('{0}' -f $n.SwitchName)
        $macColor = if ($n.DynamicMacAddressEnabled) { [ConsoleColor]::Red } else { [ConsoleColor]::Green }
        W-Row 'MAC 位址'   ('{0}  [{1}]' -f $macFmt, $macType) $macColor
    }

    # BIOS GUID / 序號
    $vmObj = $allVmObj[$vm.Name]
    if ($vmObj) {
        $setting = $allSettings[$vmObj.Name]
        if ($setting) {
            W-Row 'BIOS GUID' $setting.BIOSGUID
            if ($setting.PSObject.Properties['BaseBoardSerialNumber']) {
                W-Row 'BaseBoard SN' $setting.BaseBoardSerialNumber
            }
            if ($setting.PSObject.Properties['ChassisSerialNumber']) {
                W-Row 'Chassis SN' $setting.ChassisSerialNumber
            }
        }
    }

    # GPU 直通
    try {
        $gpu = @(Get-VMAssignableDevice -VMName $vm.Name -ErrorAction SilentlyContinue)
        if ($gpu.Count -gt 0) {
            W-Row 'GPU 直通' ($gpu.Count.ToString() + ' 顆已指派') Green
        } else {
            W-Row 'GPU 直通' '未指派' Gray
        }
    } catch {}

    # VHD 路徑
    try {
        $hdd = Get-VMHardDiskDrive -VMName $vm.Name | Select-Object -First 1
        if ($hdd) { W-Row 'VHDX' $hdd.Path }
    } catch {}
}

W-Title '驗證完成'
Write-Host ''
