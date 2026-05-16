# =========================================================
#  VM_DiagUMD_v1.0.ps1  -  GPU-PV partition UMD 綁定診斷
#
#  在 VM 內部執行 (不在主機跑)。
#
#  用途:
#    Hyper-V GPU-PV 場景下,如果 VM 內 dxdiag 顯示
#    「製造商: Microsoft / 版本 10.0.19041.x / Direct3D 無法使用」,
#    代表 Windows 沒把 NVIDIA UMD 綁到 partition device。
#
#    此腳本會抓出當前 OK 的 NVIDIA partition device,
#    把它在 registry 內的所有 UMD 路徑欄位印出來,
#    讓你判斷:
#      - OpenGLDriverName / UserModeDriverName / UserModeDriverNameXX
#        是否指向當前真實的 nv_dispi.inf_amd64_<hash>\ 資料夾
#      - 還是指向已經不存在的舊 hash (driver 升版後常見)
#
#  此工具不會修改 registry,純診斷。
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
function W-Warn($t) { Write-Host "[!] $t" -ForegroundColor Yellow }

W-Title 'GPU-PV partition UMD 綁定診斷 v1.0'

# =========================================================
#  1. 找當前真實 NVIDIA driver folder
# =========================================================
W-Step '偵測當前真實 driver folder (含 nvoglv64.dll)'
$realFolder = Get-ChildItem "$env:WinDir\System32\HostDriverStore\FileRepository" `
                -Directory -Filter 'nv*.inf_amd64_*' -ErrorAction SilentlyContinue |
              Where-Object { Test-Path (Join-Path $_.FullName 'nvoglv64.dll') } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $realFolder) {
    W-Err '找不到含 nvoglv64.dll 的 nv*.inf_amd64_* 資料夾'
    W-Info '代表 NVIDIA driver 沒搬進 VM,要先跑 Host_Master'
    return
}
W-OK ("Real folder: $($realFolder.Name)")
W-Info ("FullPath   : $($realFolder.FullName)")

# =========================================================
#  2. 找 OK 的 NVIDIA partition device
# =========================================================
W-Step '尋找 Status=OK 的 NVIDIA partition device'
$ok = Get-PnpDevice -Class Display -FriendlyName 'NVIDIA*' -Status OK -ErrorAction SilentlyContinue |
      Select-Object -First 1

if (-not $ok) {
    W-Err '找不到 Status=OK 的 NVIDIA partition device'
    W-Info 'partition 可能沒 attach,或全部是 Unknown / Error 狀態'
    W-Info '主機跑 Get-VMGpuPartitionAdapter -VMName <VM> 確認 partition 有掛'
    return
}
W-OK ("InstanceId : $($ok.InstanceId)")

$drvKey = $null
try {
    $drvKey = (Get-PnpDeviceProperty -InstanceId $ok.InstanceId `
               -KeyName 'DEVPKEY_Device_Driver' -ErrorAction Stop).Data
} catch {
    W-Err "讀取 driver subkey 失敗: $($_.Exception.Message)"
    return
}

if (-not $drvKey) {
    W-Err 'driver subkey 是空的'
    return
}
W-Info ("Driver key : $drvKey")

$cls = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$drvKey"
if (-not (Test-Path -LiteralPath $cls)) {
    W-Err "Class subkey 不存在: $cls"
    return
}

# =========================================================
#  3. 列出所有 UMD 相關欄位
# =========================================================
W-Title 'Class subkey 內容'
Write-Host "  $cls" -ForegroundColor DarkGray
Write-Host ('-' * 60)

$props = Get-ItemProperty -LiteralPath $cls

$names = @(
    # 基本資訊
    'InfPath','ProviderName','DriverDesc','MatchingDeviceId',
    'DriverVersion','DriverDate',
    # OpenGL
    'OpenGLDriverName','OpenGLDriverNameWoW','OpenGLVersion',
    # D3D9 / 主 UMD
    'UserModeDriverName','UserModeDriverNameWoW',
    # D3D10/11/12 UMD (Windows 看版本選對應的)
    'UserModeDriverName0','UserModeDriverName1','UserModeDriverName2',
    'UserModeDriverName3','UserModeDriverName4','UserModeDriverName5',
    'UserModeDriverName6','UserModeDriverName7','UserModeDriverName8',
    'UserModeDriverName9','UserModeDriverName10','UserModeDriverName11',
    # 32-bit (WoW64)
    'UserModeDriverNameWow0','UserModeDriverNameWow1','UserModeDriverNameWow2',
    'UserModeDriverNameWow3','UserModeDriverNameWow4','UserModeDriverNameWow5',
    # D3D 直接欄位
    'D3DUMDFileName','DXCoreDriverName','InstalledDisplayDrivers'
)

$staleHashCount = 0
$realHashCount  = 0
$realFolderName = $realFolder.Name

foreach ($n in $names) {
    $v = $props.$n
    if ($null -eq $v) { continue }

    $display = if ($v -is [array]) { '[' + ($v -join ' ; ') + ']' } else { [string]$v }

    # 判斷指向 hash 是不是當前真實的
    $tag = ''
    if ($display -match 'nv[\w_]+\.inf_amd64_[a-f0-9]+') {
        $hashesIn = [regex]::Matches($display, 'nv[\w_]+\.inf_amd64_[a-f0-9]+') |
                    ForEach-Object { $_.Value } | Sort-Object -Unique
        $allMatch = $true
        foreach ($h in $hashesIn) {
            if ($h -ne $realFolderName) { $allMatch = $false; break }
        }
        if ($allMatch) {
            $tag = '  [OK]'
            $realHashCount++
        } else {
            $tag = '  [STALE]'
            $staleHashCount++
        }
    }

    $line = "{0,-26} = {1}{2}" -f $n, $display, $tag
    if ($tag -eq '  [STALE]') {
        Write-Host $line -ForegroundColor Red
    } elseif ($tag -eq '  [OK]') {
        Write-Host $line -ForegroundColor Green
    } else {
        Write-Host $line
    }
}

# =========================================================
#  4. 總結
# =========================================================
W-Title '診斷結論'

W-Info ("真實 driver folder : $realFolderName")
W-Info ("指向新 hash 的欄位 : $realHashCount 個")
W-Info ("指向舊 hash 的欄位 : $staleHashCount 個")
Write-Host ''

if ($staleHashCount -gt 0) {
    W-Err  '有欄位指向已經不存在的舊 driver folder hash'
    W-Info '這就是 D3D / OpenGL / Vulkan 全死的 root cause'
    W-Info ''
    W-Info '修法:跑 VM_FixUMD_v1.0 (還沒寫,或手動更新 registry)'
    W-Info '臨時修法:把 STALE 那些欄位手動 Set-ItemProperty 改成新 hash 路徑'
} elseif ($realHashCount -gt 0) {
    W-OK '所有 UMD 路徑都指向當前真實 driver folder'
    W-Info '如果遊戲還是不行,問題不在 registry 綁定。可能方向:'
    W-Info '  1. HVCI / Memory Integrity 擋住 driver load'
    W-Info '  2. nvoglv64.dll 依賴的 DLL 缺 (跑 Host_Master 再確認 self-check)'
    W-Info '  3. Blackwell partition 在 25H2 有 init bug,降 driver 到 572.x'
} else {
    W-Warn 'registry 裡完全沒有 nv*.inf_amd64_* 路徑'
    W-Info '代表 vrd.inf 從來沒寫過 NVIDIA UMD 引用'
    W-Info '可能是 partition device 第一次安裝時 NVIDIA driver 還沒搬進 VM'
    W-Info '修法:在主機 Remove-VMGpuPartitionAdapter + Host_Master 再跑一次,順序很重要'
}

Write-Host ''
W-Info 'Tip: 把這份輸出截圖貼出來,可以一眼判斷 root cause'
Write-Host ''
