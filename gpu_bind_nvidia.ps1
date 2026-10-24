# gpu_bind_nvidia.ps1 - bind a VM's GPU partition adapter to the NVIDIA GPU.
# Works on new Hyper-V modules (-InstancePath) and old ones (WMI HostResource fallback).
# ASCII only on purpose (PS 5.1 reads BOM-less files as ANSI).
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)][string]$VMName,
    [string]$VendorMatch = '*VEN_10DE*',
    # Old Hyper-V (Win10) ignores HostResource. With this switch: temporarily disable every
    # non-target display adapter on the host, re-add the partition adapter, start the VM,
    # then re-enable the adapters. No host reboot needed.
    [switch]$TempDisableOthers
)
$ErrorActionPreference = 'Stop'

function Fail($msg) { Write-Host "[ERR] $msg" -ForegroundColor Red; exit 1 }

# 1. VM must exist and be Off
$vmObj = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vmObj) { Fail "VM not found: $VMName" }
if ($vmObj.State -ne 'Off') { Fail "VM must be Off (current: $($vmObj.State)). Shut it down and run again." }

# 2. Enumerate partitionable GPUs (new or old cmdlet)
$all = $null
try {
    if (Get-Command Get-VMHostPartitionableGpu -ErrorAction SilentlyContinue) { $all = @(Get-VMHostPartitionableGpu) }
    elseif (Get-Command Get-VMPartitionableGpu -ErrorAction SilentlyContinue) { $all = @(Get-VMPartitionableGpu) }
    else { Fail 'No partitionable-GPU cmdlet in this Hyper-V module.' }
}
catch {
    Write-Host "[!] GPU enumeration failed: $($_.Exception.Message)" -ForegroundColor Yellow
    if (-not $TempDisableOthers) { Fail 'Cannot enumerate partitionable GPUs. Re-run with -TempDisableOthers (Path C does not need enumeration).' }
    Write-Host '[!] Skipping enumeration, going straight to Path C.' -ForegroundColor Yellow
}
$target = $null
if ($all) {
    Write-Host '[*] Partitionable GPUs on host:'
    $all | ForEach-Object { Write-Host "    $($_.Name)" }
    $g = @($all | Where-Object Name -like $VendorMatch)
    if ($g.Count -eq 0) { Fail "No GPU matching $VendorMatch found. Nothing changed." }
    $target = $g[0].Name
    Write-Host "[*] Target GPU: $target" -ForegroundColor Cyan
}

# 3. MMIO settings (same as original bat)
Set-VM -Name $VMName -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 1Gb -HighMemoryMappedIoSpace 8Gb

# 4. Bind
$addHasPath = (Get-Command Add-VMGpuPartitionAdapter).Parameters.ContainsKey('InstancePath')
if (-not $target) {
    Write-Host '[*] No target path available, skipping Path A/B.'
    $bound = @()
}
elseif ($addHasPath) {
    Write-Host '[*] Path A: Add-VMGpuPartitionAdapter -InstancePath'
    Remove-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue
    Add-VMGpuPartitionAdapter -VMName $VMName -InstancePath $target
}
else {
    Write-Host '[*] Path B: old module, setting HostResource via WMI' -ForegroundColor Yellow
    if (@(Get-VMGpuPartitionAdapter -VMName $VMName).Count -eq 0) { Add-VMGpuPartitionAdapter -VMName $VMName }

    $ns = 'root\virtualization\v2'
    $cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
    if (-not $cs) { Fail 'WMI: Msvm_ComputerSystem not found for VM.' }
    $vssd = Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_VirtualSystemSettingData |
            Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' } | Select-Object -First 1
    if (-not $vssd) { Fail 'WMI: realized Msvm_VirtualSystemSettingData not found.' }
    $gpsd = @(Get-CimAssociatedInstance -InputObject $vssd -ResultClassName Msvm_GpuPartitionSettingData)
    if ($gpsd.Count -eq 0) { Fail 'WMI: Msvm_GpuPartitionSettingData not found (adapter missing?).' }
    $gpsd = $gpsd[0]
    Write-Host "[*] Current HostResource: $($gpsd.HostResource -join ';')"
    $gpsd.HostResource = [string[]]@($target)

    $ser = [Microsoft.Management.Infrastructure.Serialization.CimSerializer]::Create()
    $opt = [Microsoft.Management.Infrastructure.Serialization.InstanceSerializationOptions]::None
    $xml = [Text.Encoding]::Unicode.GetString($ser.Serialize($gpsd, $opt))
    $svc = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
    $r = Invoke-CimMethod -InputObject $svc -MethodName ModifyResourceSettings -Arguments @{ ResourceSettings = [string[]]@($xml) }
    Write-Host "[*] WMI ModifyResourceSettings ReturnValue: $($r.ReturnValue)"
    if ($r.ReturnValue -eq 4096) {
        $job = $r.Job
        do { Start-Sleep -Milliseconds 300; $job = Get-CimInstance -InputObject $job } while ($job.JobState -lt 7)
        if ($job.JobState -ne 7) { Fail "WMI job failed: state=$($job.JobState) code=$($job.ErrorCode) $($job.ErrorDescription)" }
    }
    elseif ($r.ReturnValue -ne 0) { Fail "WMI ModifyResourceSettings returned $($r.ReturnValue)" }
}

# 5. Verify (only meaningful when Path A/B ran)
$ad = @(Get-VMGpuPartitionAdapter -VMName $VMName)
if (-not $target) {
    $bound = @()
}
elseif ($ad.Count -eq 0) { Fail 'Verification failed: VM has no GPU partition adapter.' }
elseif ($ad[0].PSObject.Properties['InstancePath']) {
    $bound = @($ad | ForEach-Object { $_.InstancePath })
}
else {
    # old module: cmdlet object has no InstancePath, read HostResource back from WMI
    $ns = 'root\virtualization\v2'
    $cs = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$VMName'"
    $vssd = Get-CimAssociatedInstance -InputObject $cs -ResultClassName Msvm_VirtualSystemSettingData |
            Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' } | Select-Object -First 1
    $gpsd = @(Get-CimAssociatedInstance -InputObject $vssd -ResultClassName Msvm_GpuPartitionSettingData)
    $bound = @($gpsd | ForEach-Object { $_.HostResource })
}
Write-Host "[*] Bound now: $($bound -join ';')"
$chk = @($bound | Where-Object { $_ -like $VendorMatch })
if ($chk.Count -gt 0) {
    Write-Host "[OK] VM $VMName is now bound to: $($chk[0])" -ForegroundColor Green
    exit 0
}
if (-not $TempDisableOthers) {
    Fail "Verification failed. Adapter HostResource is: '$($bound -join ';')' (empty = this Hyper-V build picks the GPU itself; re-run with -TempDisableOthers)"
}

# 6. Last resort for old Hyper-V: hide the other GPUs while the VM picks one.
Write-Host '[*] Path C: temporarily disabling non-target display adapters on host' -ForegroundColor Yellow
$others = @(Get-PnpDevice -Class Display -Status OK | Where-Object { $_.InstanceId -notlike $VendorMatch })
Get-PnpDevice -Class Display | ForEach-Object { Write-Host "    display adapter: $($_.FriendlyName) status=$($_.Status)" }
if ($others.Count -eq 0) { Write-Host '[!] No other ENABLED display adapter found (already disabled?). Continuing with only the target visible.' -ForegroundColor Yellow }
$others | ForEach-Object { Write-Host "    disabling: $($_.FriendlyName) [$($_.InstanceId)]" }
$disabled = @()
try {
    foreach ($d in $others) {
        Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
        $disabled += $d
    }
    Start-Sleep -Seconds 3
    Remove-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue
    Add-VMGpuPartitionAdapter -VMName $VMName
    Write-Host '[*] Starting VM so it binds the GPU while only the target is visible...'
    Start-VM -Name $VMName
    $deadline = (Get-Date).AddSeconds(90)
    do {
        Start-Sleep -Seconds 3
        $hb = (Get-VMIntegrationService -VMName $VMName -Name Heartbeat -ErrorAction SilentlyContinue).PrimaryStatusDescription
    } while ($hb -ne 'OK' -and (Get-Date) -lt $deadline)
    Write-Host "[*] VM heartbeat: $hb (waited until $(Get-Date -Format HH:mm:ss))"
    Start-Sleep -Seconds 10
}
finally {
    foreach ($d in $disabled) {
        Write-Host "    re-enabling: $($d.FriendlyName)"
        Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction Continue
    }
}
Write-Host '[OK] Path C done. VM is running. Check inside the VM (dxdiag / Device Manager) that it shows the NVIDIA GPU.' -ForegroundColor Green
Write-Host '[!] NOTE: on this Hyper-V build the choice is made at VM start. If a later VM start picks the iGPU again, run this tool again.' -ForegroundColor Yellow
exit 0
