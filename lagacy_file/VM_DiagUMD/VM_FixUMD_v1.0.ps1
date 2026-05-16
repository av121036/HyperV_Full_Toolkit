# =========================================================
#  VM_FixUMD_v1.0.ps1  -  GPU-PV partition D3D UMD 路徑修補
#
#  在 VM 內部執行 (不在主機跑)。
#
#  解決問題:
#    VM_DiagUMD 顯示 Class subkey 內只有 OpenGLDriverName /
#    UserModeDriverName / UserModeDriverNameWoW 三個欄位,
#    缺 D3D10/11/12 系列的 UserModeDriverNameX / D3DUMDFileName /
#    DXCoreDriverName / InstalledDisplayDrivers
#    導致 dxdiag「製造商 Microsoft / 版本 10.0.19041.1」,
#    Vulkan vkCreateDevice 失敗,遊戲跳 cannot OpenGL。
#
#  此腳本會:
#    1. 自動偵測當前真實 driver folder (含 nvoglv64.dll)
#    2. 找出所有 Status=OK 的 Display Class subkey (vrd.inf + wvmbusvideo.inf)
#    3. 寫入完整的 D3D UMD 路徑欄位,指向真實 driver folder
#    4. 跑完建議 VM 重開機
#
#  Note: GPUWakeup v1.2 的 self-heal 漏寫這些欄位,所以 driver 升版
#        後一升就必跑此 fix (或之後改 GPU_Wakeup.ps1 加入這段邏輯)。
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

W-Title 'GPU-PV partition D3D UMD 路徑修補 v1.0'

# =========================================================
#  1. 預檢:管理員權限
# =========================================================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] 'Administrator')
if (-not $isAdmin) {
    W-Err '需要系統管理員權限'
    exit 1
}

# =========================================================
#  2. 偵測真實 driver folder
# =========================================================
W-Step '偵測當前真實 NVIDIA driver folder'
$realFolder = Get-ChildItem "$env:WinDir\System32\HostDriverStore\FileRepository" `
                -Directory -Filter 'nv*.inf_amd64_*' -ErrorAction SilentlyContinue |
              Where-Object { Test-Path (Join-Path $_.FullName 'nvoglv64.dll') } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $realFolder) {
    W-Err '找不到含 nvoglv64.dll 的 nv*.inf_amd64_* 資料夾'
    W-Info '先在主機跑 Host_Master 把 driver 推進 VM 再回來跑此工具'
    exit 1
}
W-OK ("Real folder: $($realFolder.Name)")

# =========================================================
#  3. 組出所有 UMD 檔案的完整路徑
# =========================================================
$folder = $realFolder.FullName
$paths = [ordered]@{
    nvldumdx  = Join-Path $folder 'nvldumdx.dll'    # D3D9   64-bit (legacy DXGI UMD)
    nvwgf2umx = Join-Path $folder 'nvwgf2umx.dll'   # D3D10+ 64-bit (modern WDF2 UMD)
    nvoglv64  = Join-Path $folder 'nvoglv64.dll'    # OpenGL 64-bit / Vulkan ICD
    nvldumd   = Join-Path $folder 'nvldumd.dll'     # D3D9   32-bit
    nvwgf2um  = Join-Path $folder 'nvwgf2um.dll'    # D3D10+ 32-bit
    nvoglv32  = Join-Path $folder 'nvoglv32.dll'    # OpenGL 32-bit
}

W-Step '檢查 UMD 檔案是否齊全'
$missing64 = 0
foreach ($k in $paths.Keys) {
    $exists = Test-Path $paths[$k]
    $tag = if ($exists) { '[+]' } else { '[X]' }
    $color = if ($exists) { 'Green' } else { 'Red' }
    Write-Host ("  $tag $k`t-> $($paths[$k])") -ForegroundColor $color
    if (-not $exists -and $k -in @('nvldumdx','nvwgf2umx','nvoglv64')) {
        $missing64++
    }
}

if ($missing64 -gt 0) {
    W-Err ('缺 ' + $missing64 + ' 個關鍵 64-bit UMD,跑主機 Host_Master 再回來')
    exit 1
}
W-OK '關鍵 64-bit UMD 都在'

# =========================================================
#  4. 列出要修補的 Display Class subkey
# =========================================================
W-Step '列出要修補的 Display Class subkey'
$displayClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'

$targets = @()
Get-ChildItem $displayClass -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.PSChildName -notmatch '^\d{4}$') { return }
    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if (-not $p) { return }
    if ($p.InfPath -in @('vrd.inf','wvmbusvideo.inf')) {
        $targets += [PSCustomObject]@{
            Sub  = $_.PSChildName
            Path = $_.PSPath
            Inf  = $p.InfPath
            Desc = $p.DriverDesc
        }
    }
}

if ($targets.Count -eq 0) {
    W-Err '找不到 vrd.inf / wvmbusvideo.inf subkey'
    exit 1
}

foreach ($t in $targets) {
    W-Info ("  Sub=$($t.Sub)  $($t.Inf)  ($($t.Desc))")
}
W-OK ("共 $($targets.Count) 個 subkey 要修補")

# =========================================================
#  5. 寫入 D3D UMD 路徑
# =========================================================
W-Title '寫入完整 D3D UMD 路徑'

# 准備 multi-string 值 (NVIDIA 慣例 4 個重複)
$mUmdx  = @($paths.nvldumdx,  $paths.nvldumdx,  $paths.nvldumdx,  $paths.nvldumdx)
$mWgf64 = @($paths.nvwgf2umx, $paths.nvwgf2umx, $paths.nvwgf2umx, $paths.nvwgf2umx)
$mOgl64 = @($paths.nvoglv64)

$mUmd32 = if (Test-Path $paths.nvldumd)  { @($paths.nvldumd,  $paths.nvldumd,  $paths.nvldumd,  $paths.nvldumd)  } else { $null }
$mWgf32 = if (Test-Path $paths.nvwgf2um) { @($paths.nvwgf2um, $paths.nvwgf2um, $paths.nvwgf2um, $paths.nvwgf2um) } else { $null }
$mOgl32 = if (Test-Path $paths.nvoglv32) { @($paths.nvoglv32) } else { $null }

# 安全寫入函式
function Set-Reg($keyPath, $name, $value, $type) {
    try {
        New-ItemProperty -Path $keyPath -Name $name -Value $value -PropertyType $type -Force -ErrorAction Stop | Out-Null
        return $true
    } catch {
        W-Warn ("    寫入 $name 失敗: $($_.Exception.Message)")
        return $false
    }
}

$totalWritten = 0
foreach ($t in $targets) {
    Write-Host ''
    W-Step ("修補 Sub=$($t.Sub) ($($t.Inf))")
    $written = 0

    # ---- 64-bit ----
    # D3D9 主 UMD
    if (Set-Reg $t.Path 'UserModeDriverName'   $mUmdx  'MultiString') { $written++ }
    # OpenGL
    if (Set-Reg $t.Path 'OpenGLDriverName'     $mOgl64 'MultiString') { $written++ }
    if (Set-Reg $t.Path 'OpenGLVersion'        4096    'DWord')       { $written++ }
    # D3D10 / 10.1 / 11 / 11.1 / 11.2 / 12 (index 0~5)
    for ($i = 0; $i -le 5; $i++) {
        if (Set-Reg $t.Path "UserModeDriverName$i" $mWgf64 'MultiString') { $written++ }
    }
    # 給 DX12 / DXCore 用 (REG_SZ,單一檔案路徑)
    if (Set-Reg $t.Path 'D3DUMDFileName'    $paths.nvwgf2umx 'String') { $written++ }
    if (Set-Reg $t.Path 'DXCoreDriverName'  $paths.nvwgf2umx 'String') { $written++ }
    # InstalledDisplayDrivers (Windows 用來辨識「裝了什麼 display driver」)
    $idd = @('nvldumdx','nvldumdx','nvldumdx','nvldumdx')
    if (Set-Reg $t.Path 'InstalledDisplayDrivers' $idd 'MultiString') { $written++ }

    # ---- 32-bit (WoW64) ----
    if ($mUmd32)  { if (Set-Reg $t.Path 'UserModeDriverNameWoW' $mUmd32 'MultiString') { $written++ } }
    if ($mOgl32)  { if (Set-Reg $t.Path 'OpenGLDriverNameWoW'   $mOgl32 'MultiString') { $written++ } }
    if ($mWgf32) {
        for ($i = 0; $i -le 5; $i++) {
            if (Set-Reg $t.Path "UserModeDriverNameWow$i" $mWgf32 'MultiString') { $written++ }
        }
    }

    W-OK ("  Sub=$($t.Sub) 寫入 $written 個欄位")
    $totalWritten += $written
}

Write-Host ''
W-OK ("總共寫入 $totalWritten 個 registry 欄位")

# =========================================================
#  6. 驗證
# =========================================================
W-Title '驗證寫入結果'

foreach ($t in $targets) {
    $p = Get-ItemProperty $t.Path -ErrorAction SilentlyContinue
    $checkNames = @('UserModeDriverName','UserModeDriverName0','UserModeDriverName1',
                    'UserModeDriverName2','UserModeDriverName3','UserModeDriverName4',
                    'UserModeDriverName5','D3DUMDFileName','DXCoreDriverName',
                    'OpenGLDriverName','InstalledDisplayDrivers')
    $okCount = 0
    foreach ($n in $checkNames) {
        if ($null -ne $p.$n) { $okCount++ }
    }
    W-Info ("  Sub=$($t.Sub)  $okCount / $($checkNames.Count) 個關鍵欄位有值")
}

# =========================================================
#  7. 結尾
# =========================================================
W-Title '完成'
Write-Host ''
Write-Host ' 接下來:' -ForegroundColor White
Write-Host '   1. VM 重開機 (一定要)' -ForegroundColor Gray
Write-Host '   2. 登入後跑 dxdiag,看「轉譯」分頁:' -ForegroundColor Gray
Write-Host '      - 製造商    : 應該變 NVIDIA (不是 Microsoft)' -ForegroundColor Gray
Write-Host '      - 版本      : 應該變 32.0.15.96xx (不是 10.0.19041.x)' -ForegroundColor Gray
Write-Host '      - Direct3D  : 已啟用' -ForegroundColor Gray
Write-Host '      - DDI       : 12 或更高' -ForegroundColor Gray
Write-Host '      - 功能層級  : 12_2 / 12_1 / 12_0 ...' -ForegroundColor Gray
Write-Host '   3. 跑 vulkaninfo-x64.exe --summary,應該看到' -ForegroundColor Gray
Write-Host '      deviceName = NVIDIA GeForce RTX 5080' -ForegroundColor Gray
Write-Host '   4. 開遊戲應該不再跳 cannot OpenGL' -ForegroundColor Gray
Write-Host ''
Write-Host ' 注意:' -ForegroundColor Yellow
Write-Host '   主機 NVIDIA driver 升級後 folder hash 會改,' -ForegroundColor Gray
Write-Host '   要再跑一次此工具 (跑 Host_Master 之後)' -ForegroundColor Gray
Write-Host ''
