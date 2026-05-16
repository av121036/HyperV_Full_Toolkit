# =========================================================
#  VM_DiagDeep_v1.0.ps1  -  深度診斷 GPU-PV partition 為何 D3D 死
#
#  在 VM 內部執行 (admin)。
#  輸出夠多資訊讓人從外部判斷:
#   - HVCI / VBS 實際狀態
#   - Windows build / NVIDIA driver 版本
#   - NVIDIA partition device PnP problem code
#   - 全部 Display / DXGK / Kernel-PnP 錯誤事件 (24 小時)
#   - nvldumdx.dll 真實版本與 size
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

# =========================================================
#  1. OS / build / VBS / HVCI 狀態
# =========================================================
W-Title 'OS / VBS / HVCI 狀態'

$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("OS Caption    : " + $os.Caption)
Write-Host ("Build         : " + $os.BuildNumber + '.' + $os.ServicePackMajorVersion)
Write-Host ("Version       : " + $os.Version)

try {
    $dg = Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
    $vbsMap = @{ 0='Off'; 1='Configured but not running'; 2='Running' }
    $svcMap = @{ 1='CredentialGuard'; 2='HVCI'; 3='SecureLaunch'; 4='SMM' }
    Write-Host ("VBS Status    : " + $vbsMap[[int]$dg.VirtualizationBasedSecurityStatus])
    $running = @($dg.SecurityServicesRunning) | ForEach-Object { $svcMap[[int]$_] }
    Write-Host ("Services Run  : " + ($running -join ', '))
    Write-Host ("Required      : " + (@($dg.RequiredSecurityProperties) -join ', '))
} catch {
    Write-Host "Win32_DeviceGuard query failed: $($_.Exception.Message)" -ForegroundColor Red
}

# =========================================================
#  2. NVIDIA driver 版本檢查
# =========================================================
W-Title 'NVIDIA UMD / KMD 版本'

$dlls = @('nvldumdx.dll','nvwgf2umx.dll','nvoglv64.dll','nvapi64.dll','nvcuda.dll')
foreach ($d in $dlls) {
    $p = "C:\Windows\System32\$d"
    if (Test-Path $p) {
        $v = (Get-Item $p).VersionInfo
        $sz = [math]::Round((Get-Item $p).Length / 1MB, 2)
        Write-Host ("  {0,-18} {1,8} MB  v{2,-20} {3}" -f $d, $sz, $v.FileVersion, $v.CompanyName)
    } else {
        Write-Host ("  {0,-18} MISSING" -f $d) -ForegroundColor Red
    }
}

$kmd = "C:\Windows\System32\drivers\nvlddmkm.sys"
if (Test-Path $kmd) {
    $v = (Get-Item $kmd).VersionInfo
    Write-Host ("  {0,-18} {1,8} MB  v{2,-20} {3}" -f 'nvlddmkm.sys', ([math]::Round((Get-Item $kmd).Length/1MB,2)), $v.FileVersion, $v.CompanyName)
}

# =========================================================
#  3. PnP device problem code (Status=OK 不代表 Problem=0)
# =========================================================
W-Title 'NVIDIA partition device PnP 狀態'

$devs = Get-PnpDevice -Class Display -FriendlyName 'NVIDIA*' -ErrorAction SilentlyContinue
foreach ($d in $devs) {
    Write-Host ('-' * 60)
    Write-Host ("InstanceId : " + $d.InstanceId)
    Write-Host ("Status     : " + $d.Status)
    Write-Host ("Class      : " + $d.Class)
    try {
        $pProb = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue
        $pStat = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemStatus' -ErrorAction SilentlyContinue
        $pDriverInf = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue
        $pDriverVer = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_DriverVersion' -ErrorAction SilentlyContinue
        $pInstall   = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_InstallDate' -ErrorAction SilentlyContinue
        Write-Host ("ProblemCode: " + $pProb.Data)
        Write-Host ("ProblemStat: " + $pStat.Data)
        Write-Host ("DriverInf  : " + $pDriverInf.Data)
        Write-Host ("DriverVer  : " + $pDriverVer.Data)
        Write-Host ("InstallDate: " + $pInstall.Data)
    } catch {
        Write-Host "  Property query error: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# =========================================================
#  4. Service / KMD load 狀態
# =========================================================
W-Title 'KMD service 狀態'
$svcs = @('nvlddmkm','BasicRender','BasicDisplay','dxgkrnl','vrd')
foreach ($n in $svcs) {
    $s = Get-CimInstance Win32_SystemDriver -Filter "Name='$n'" -ErrorAction SilentlyContinue
    if ($s) {
        Write-Host ("  {0,-15}  State={1,-10} StartMode={2,-10} PathName={3}" -f $n, $s.State, $s.StartMode, $s.PathName)
    } else {
        Write-Host ("  {0,-15}  (not found)" -f $n) -ForegroundColor DarkGray
    }
}

# =========================================================
#  5. 最近 24 小時 Display 相關事件
# =========================================================
W-Title '最近 24 小時 Display / Kernel-PnP / DXGK 事件 (Error + Warning)'

try {
    $events = Get-WinEvent -FilterHashtable @{
        LogName='System'
        Level=1,2,3
        StartTime=(Get-Date).AddHours(-24)
    } -ErrorAction Stop |
    Where-Object {
        $_.ProviderName -match 'Display|nvlddmkm|DXGK|Kernel-PnP|VrDispDriver|vrd|Hyper-V|Video' -or
        $_.Message -match 'NVIDIA|nvldumdx|nvoglv|nvwgf2|partition|GPU'
    } |
    Select-Object -First 30

    if (-not $events) {
        Write-Host '  (24 小時內沒有匹配事件)' -ForegroundColor Yellow
    } else {
        foreach ($e in $events) {
            Write-Host ('-' * 60) -ForegroundColor DarkGray
            Write-Host ("Time     : " + $e.TimeCreated)
            Write-Host ("Provider : " + $e.ProviderName + "  ID=" + $e.Id + "  Level=" + $e.LevelDisplayName)
            $msg = $e.Message
            if ($msg) {
                $msg = $msg.Substring(0, [Math]::Min(300, $msg.Length))
                Write-Host ("Message  : " + $msg)
            }
        }
    }
} catch {
    Write-Host "Event log query failed: $($_.Exception.Message)" -ForegroundColor Red
}

# =========================================================
#  6. dxdiag 文字輸出 (轉譯分頁全文)
# =========================================================
W-Title 'dxdiag 輸出 (display devices)'

$dxOut = "$env:TEMP\dx_diag.txt"
& dxdiag /t $dxOut
$retry = 0
while (-not (Test-Path $dxOut) -and $retry -lt 15) {
    Start-Sleep -Seconds 2
    $retry++
}

if (Test-Path $dxOut) {
    $content = Get-Content $dxOut -Raw
    # 抓 Display Devices 段
    $match = [regex]::Match($content, '(?ms)Display Devices.*?(?=Sound Devices|Audio Devices|Video Capture)')
    if ($match.Success) {
        Write-Host $match.Value
    } else {
        Write-Host '(could not find Display Devices section)'
    }
    Remove-Item $dxOut -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host ' 完成。請把整個輸出複製貼上來。' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
