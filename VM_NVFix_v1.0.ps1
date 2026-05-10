# =========================================================
#  VM_NVFix_v1.0.ps1  -  GPU-PV NVIDIA OpenGL/D3D ICD 修補
#                       (VM 內部執行,不在主機跑)
#  v1.0
#    解決 GPU-PV 直通後 OpenGL / D3D 程式回報「no driver」
#    或顯示為「Microsoft Basic Render Driver」的問題
#
#  通用化設計 (跨機器/跨 NVIDIA 驅動版本/跨 VM 設定):
#    - 自動偵測 nvmdsi.inf_amd64_<hash> 資料夾
#      優先順序: HostDriverStore > DriverStore
#    - 自動找出所有綁到 vrd.inf 的虛擬顯示卡 Class 子鍵
#    - 寫入 OpenGLDriverName / OpenGLVersion /
#           UserModeDriverName / UserModeDriverNameWoW
#    - 備份原值到 C:\ProgramData\VM_NVFix\backup\
#    - 可選:建立開機重套用排程 (防 PnP 還原)
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

# =========================================================
#  通用:倒數預設值輸入 (5 秒沒動就用預設)
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

W-Title 'GPU-PV NVIDIA OpenGL/D3D ICD 修補工具 v1.0'

Write-Host ''
Write-Host ' 適用情境:' -ForegroundColor White
Write-Host '   - 已用 Host_Master 把 NVIDIA 驅動搬進 VM' -ForegroundColor Gray
Write-Host '   - VM 開機後裝置管理員看得到「NVIDIA GeForce ...」' -ForegroundColor Gray
Write-Host '   - 但 OpenGL / 部分 D3D 程式回報「no driver」' -ForegroundColor Gray
Write-Host '   - 或 dxdiag 顯示為 Microsoft Basic Render Driver' -ForegroundColor Gray
Write-Host ''

# =========================================================
#  1. 環境檢查
# =========================================================
W-Step '環境檢查'

# 檢查管理員權限
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] 'Administrator')
if (-not $isAdmin) {
    W-Err '需要系統管理員權限'
    W-Info '請用 .bat 啟動器重跑,它會自動檢查管理員權限'
    exit 1
}
W-OK '管理員權限 OK'

# 檢查是不是在 VM (用幾個指標粗略判斷)
$isVM = $false
try {
    $sys = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($sys.Manufacturer -match 'Microsoft|VMware|VirtualBox|innotek|QEMU|Xen' `
        -or $sys.Model -match 'Virtual|VMware|VirtualBox') {
        $isVM = $true
    }
} catch {}
if ($isVM) {
    W-OK '偵測到虛擬機環境'
} else {
    W-Warn '不像是在 VM 內,本工具是寫給 GPU-PV VM 用的'
    $cont = Read-WithDefault -Prompt '還是要繼續嗎? (Y/N)' -Default 'N' -Seconds 5
    if ($cont -notmatch '^[Yy]') { exit 1 }
}

# =========================================================
#  2. 自動偵測 NVIDIA INF 資料夾 (跨驅動版本通用)
# =========================================================
W-Step '搜尋 NVIDIA 顯示驅動資料夾 (含 nvoglv64.dll)'

$searchRoots = @(
    "$env:WinDir\System32\HostDriverStore\FileRepository",   # GPU-PV 標準位置
    "$env:WinDir\System32\DriverStore\FileRepository"        # 一般 DriverStore
)

$foundFolder = $null
$foundRoot   = $null

foreach ($root in $searchRoots) {
    if (-not (Test-Path $root)) { continue }
    $candidates = Get-ChildItem $root -Filter 'nv*.inf_amd64_*' -Directory -ErrorAction SilentlyContinue
    $valid = @()
    foreach ($c in $candidates) {
        # 必要檔案三件組:OpenGL ICD + D3D UMD 64/32
        $hasOgl   = Test-Path (Join-Path $c.FullName 'nvoglv64.dll')
        $hasUmd64 = Test-Path (Join-Path $c.FullName 'nvldumdx.dll')
        if ($hasOgl -and $hasUmd64) { $valid += $c }
    }
    if ($valid.Count -gt 0) {
        # 多個就挑最新的
        $foundFolder = $valid | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $foundRoot   = $root
        break
    }
}

if (-not $foundFolder) {
    W-Err '找不到含 nvoglv64.dll + nvldumdx.dll 的 NVIDIA 驅動資料夾'
    W-Info '搜尋過的位置:'
    foreach ($root in $searchRoots) { W-Info ('  ' + $root) }
    W-Info ''
    W-Info '可能原因:'
    W-Info '  1. 還沒在主機跑過 Host_Master 把驅動搬進 VM'
    W-Info '  2. 搬過了但檔案路徑不對'
    W-Info '請先確認主機 + Host_Master 流程跑完再回來'
    exit 1
}

$nvFolder = $foundFolder.FullName
$nvName   = $foundFolder.Name
W-OK ('找到 NVIDIA 驅動資料夾')
W-Info ('  名稱  : ' + $nvName)
W-Info ('  位置  : ' + $foundRoot)
W-Info ('  完整  : ' + $nvFolder)

# 列出三個關鍵 DLL 是否齊全
$openglDll = Join-Path $nvFolder 'nvoglv64.dll'
$umd64Dll  = Join-Path $nvFolder 'nvldumdx.dll'
$umd32Dll  = Join-Path $nvFolder 'nvldumd.dll'

$dllReport = @(
    @{ Name = 'nvoglv64.dll (OpenGL ICD)';   Path = $openglDll; Required = $true  }
    @{ Name = 'nvldumdx.dll (D3D UMD x64)';  Path = $umd64Dll;  Required = $true  }
    @{ Name = 'nvldumd.dll  (D3D UMD WoW)';  Path = $umd32Dll;  Required = $false }
)

$missingRequired = $false
foreach ($d in $dllReport) {
    if (Test-Path $d.Path) {
        $size = (Get-Item $d.Path).Length
        W-Info ('  [OK] {0,-30} {1,12:N0} bytes' -f $d.Name, $size)
    } else {
        if ($d.Required) {
            W-Err ('  [缺] ' + $d.Name + '  <-- 必要檔案!')
            $missingRequired = $true
        } else {
            W-Warn ('  [缺] ' + $d.Name + '  (非必要,32-bit 程式才需要)')
        }
    }
}
if ($missingRequired) {
    W-Err '必要檔案缺漏,中止'
    exit 1
}

# =========================================================
#  3. 自動找出所有 vrd.inf 的 Class 子鍵 (跨 VM 設定通用)
# =========================================================
W-Step '搜尋 GPU-PV 虛擬顯示卡 Class 子鍵 (vrd.inf)'

$displayClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
if (-not (Test-Path $displayClass)) {
    W-Err '找不到顯示卡裝置類別登錄檔,系統異常'
    exit 1
}

$targets = @()
Get-ChildItem $displayClass -ErrorAction SilentlyContinue | ForEach-Object {
    $sub = $_.PSChildName
    # 只處理 0000-9999 這種子鍵 (跳過 Configuration 等)
    if ($sub -notmatch '^\d{4}$') { return }

    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    if (-not $props) { return }

    if ($props.InfPath -eq 'vrd.inf') {
        $hasOgl = -not [string]::IsNullOrEmpty($props.OpenGLDriverName)
        $targets += [PSCustomObject]@{
            SubKey      = $sub
            Path        = $_.PSPath
            DriverDesc  = $props.DriverDesc
            HasOpenGL   = $hasOgl
        }
    }
}

if ($targets.Count -eq 0) {
    W-Err '找不到任何綁到 vrd.inf 的 Class 子鍵'
    W-Info '這表示 Hyper-V GPU-PV 虛擬顯示卡沒被建立'
    W-Info '可能 Add-VMGpuPartitionAdapter 失敗,先回主機檢查'
    exit 1
}

W-OK ('找到 ' + $targets.Count + ' 個 vrd.inf 子鍵需要修補')
foreach ($t in $targets) {
    $tag = if ($t.HasOpenGL) { ' [已設定 OpenGL]' } else { ' [未設定 OpenGL]' }
    W-Info ('  Class\' + $t.SubKey + '  ' + $t.DriverDesc + $tag)
}

# =========================================================
#  4. 顯示計畫 + 確認
# =========================================================
W-Title '修補計畫'
Write-Host '  將寫入下列值到上面所有 vrd.inf 子鍵:' -ForegroundColor White
Write-Host ''
Write-Host ('  OpenGLDriverName     = ' + $openglDll) -ForegroundColor Gray
Write-Host  '  OpenGLVersion        = 0x00001000 (4096)' -ForegroundColor Gray
Write-Host ('  UserModeDriverName   = ' + $umd64Dll + ' (×4 D3D9/10/11/12)') -ForegroundColor Gray
if (Test-Path $umd32Dll) {
    Write-Host ('  UserModeDriverNameWoW= ' + $umd32Dll + ' (×4)') -ForegroundColor Gray
}
Write-Host ''
Write-Host '  原值會備份到 C:\ProgramData\VM_NVFix\backup\' -ForegroundColor Gray
Write-Host ''

$go = Read-WithDefault -Prompt '確認執行修補? (Y/N)' -Default 'Y' -Seconds 8
if ($go -notmatch '^[Yy]') {
    W-Warn '使用者取消'
    exit 0
}

# =========================================================
#  5. 備份 + 寫入
# =========================================================
$backupDir = 'C:\ProgramData\VM_NVFix\backup'
if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

$umd64Multi = @($umd64Dll, $umd64Dll, $umd64Dll, $umd64Dll)
$umd32Multi = @($umd32Dll, $umd32Dll, $umd32Dll, $umd32Dll)

$writeOK   = 0
$writeFail = 0

foreach ($t in $targets) {
    W-Step ('修補子鍵 Class\' + $t.SubKey + '  (' + $t.DriverDesc + ')')

    # 備份
    try {
        $bkPath = Join-Path $backupDir ("class_{0}_{1}.reg" -f $t.SubKey, $timestamp)
        $regPath = "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\$($t.SubKey)"
        & reg.exe export $regPath $bkPath /y | Out-Null
        W-Info ('  備份 -> ' + $bkPath)
    } catch {
        W-Warn ('  備份失敗 (繼續): ' + $_.Exception.Message)
    }

    # 寫入 OpenGL ICD
    try {
        New-ItemProperty -Path $t.Path -Name 'OpenGLDriverName' `
            -Value @($openglDll) -PropertyType MultiString -Force | Out-Null
        New-ItemProperty -Path $t.Path -Name 'OpenGLVersion' `
            -Value 4096 -PropertyType DWord -Force | Out-Null
        W-Info '  OpenGL ICD .................. OK'
    } catch {
        W-Err ('  OpenGL ICD 寫入失敗: ' + $_.Exception.Message)
        $writeFail++
        continue
    }

    # 寫入 D3D UMD x64
    try {
        New-ItemProperty -Path $t.Path -Name 'UserModeDriverName' `
            -Value $umd64Multi -PropertyType MultiString -Force | Out-Null
        W-Info '  D3D UMD x64 ................. OK'
    } catch {
        W-Err ('  D3D UMD x64 寫入失敗: ' + $_.Exception.Message)
        $writeFail++
        continue
    }

    # 寫入 D3D UMD WoW (32-bit, 可選)
    if (Test-Path $umd32Dll) {
        try {
            New-ItemProperty -Path $t.Path -Name 'UserModeDriverNameWoW' `
                -Value $umd32Multi -PropertyType MultiString -Force | Out-Null
            W-Info '  D3D UMD WoW (32-bit) ........ OK'
        } catch {
            W-Warn ('  D3D UMD WoW 寫入失敗 (32-bit 程式會用不到): ' + $_.Exception.Message)
        }
    }

    $writeOK++
}

W-Title '修補結果'
W-OK  ("成功: $writeOK / $($targets.Count) 個子鍵")
if ($writeFail -gt 0) { W-Err ("失敗: $writeFail 個子鍵") }

# =========================================================
#  6. 驗證寫入
# =========================================================
W-Step '驗證寫入結果'
foreach ($t in $targets) {
    $p = Get-ItemProperty $t.Path -ErrorAction SilentlyContinue
    $ogl = if ($p.OpenGLDriverName) { '✓' } else { '✗' }
    $umd = if ($p.UserModeDriverName) { '✓' } else { '✗' }
    $wow = if ($p.UserModeDriverNameWoW) { '✓' } else { '-' }
    W-Info ('  Class\' + $t.SubKey + '  OpenGL:' + $ogl + '  UMD64:' + $umd + '  UMD32:' + $wow)
}

# =========================================================
#  7. 可選:建立開機重套用排程 (防 PnP 還原)
# =========================================================
Write-Host ''
W-Step '開機自動重套用排程'
Write-Host '    Windows 偶爾會在 PnP 重掃時用 vrd.inf 預設值蓋掉我們的修補。' -ForegroundColor Gray
Write-Host '    建議建立排程,每次開機自動重套用一次,確保 OpenGL 持續可用。' -ForegroundColor Gray

$mkTask = Read-WithDefault -Prompt '要建立嗎? (Y/N,建議 Y)' -Default 'Y' -Seconds 5

if ($mkTask -match '^[Yy]') {
    try {
        $taskFolder = 'C:\ProgramData\VM_NVFix'
        if (-not (Test-Path $taskFolder)) { New-Item -Path $taskFolder -ItemType Directory -Force | Out-Null }

        $bootScript = @'
# VM_NVFix boot reapply - auto-generated
# 開機後重新套用 NVIDIA OpenGL/D3D ICD 註冊
$ErrorActionPreference = 'Continue'
$logPath = 'C:\ProgramData\VM_NVFix\boot.log'
function L($m) { Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

try {
    # 動態找 NVIDIA 資料夾 (驅動升級後 hash 會變)
    $roots = @(
        "$env:WinDir\System32\HostDriverStore\FileRepository",
        "$env:WinDir\System32\DriverStore\FileRepository"
    )
    $nvFolder = $null
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $cand = Get-ChildItem $r -Filter 'nv*.inf_amd64_*' -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'nvoglv64.dll') } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
        if ($cand) { $nvFolder = $cand.FullName; break }
    }
    if (-not $nvFolder) { L 'ERR: nvoglv64.dll folder not found'; return }

    $openglDll = Join-Path $nvFolder 'nvoglv64.dll'
    $umd64Dll  = Join-Path $nvFolder 'nvldumdx.dll'
    $umd32Dll  = Join-Path $nvFolder 'nvldumd.dll'

    $umd64Multi = @($umd64Dll, $umd64Dll, $umd64Dll, $umd64Dll)
    $umd32Multi = @($umd32Dll, $umd32Dll, $umd32Dll, $umd32Dll)

    # 等 PnP 完成 (最多 30 秒)
    $displayClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $retry = 0
    while ($retry -lt 15) {
        $found = Get-ChildItem $displayClass -ErrorAction SilentlyContinue |
                 Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).InfPath -eq 'vrd.inf' }
        if ($found) { break }
        Start-Sleep -Seconds 2
        $retry++
    }

    $count = 0
    Get-ChildItem $displayClass -ErrorAction SilentlyContinue | ForEach-Object {
        $sub = $_.PSChildName
        if ($sub -notmatch '^\d{4}$') { return }
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.InfPath -ne 'vrd.inf') { return }

        New-ItemProperty -Path $_.PSPath -Name 'OpenGLDriverName' -Value @($openglDll) -PropertyType MultiString -Force | Out-Null
        New-ItemProperty -Path $_.PSPath -Name 'OpenGLVersion' -Value 4096 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $_.PSPath -Name 'UserModeDriverName' -Value $umd64Multi -PropertyType MultiString -Force | Out-Null
        if (Test-Path $umd32Dll) {
            New-ItemProperty -Path $_.PSPath -Name 'UserModeDriverNameWoW' -Value $umd32Multi -PropertyType MultiString -Force | Out-Null
        }
        $count++
    }
    L ("OK reapplied $count subkeys, folder=" + (Split-Path $nvFolder -Leaf))
} catch {
    L ('ERR: ' + $_.Exception.Message)
}
'@
        $bootScriptPath = Join-Path $taskFolder 'Apply_Boot.ps1'
        Set-Content -Path $bootScriptPath -Value $bootScript -Encoding UTF8

        $taskName = 'VM_NVFix_BootApply'
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                      -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootScriptPath`""
        $trigger   = New-ScheduledTaskTrigger -AtStartup
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                      -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                              -Principal $principal -Settings $settings `
                              -Description 'VM_NVFix - reapply NVIDIA OpenGL/D3D ICD after boot' `
                              -Force | Out-Null

        W-OK ('排程已建立: ' + $taskName)
        W-Info ('  腳本: ' + $bootScriptPath)
        W-Info ('  Log : C:\ProgramData\VM_NVFix\boot.log')
    } catch {
        W-Err ('排程建立失敗: ' + $_.Exception.Message)
    }
} else {
    W-Info '已跳過。如果重開機後 OpenGL 又失效,請再跑一次本工具,或手動建立排程。'
}

# =========================================================
#  8. 總結 + 重開機提示
# =========================================================
W-Title '完成'
Write-Host ''
Write-Host '  下一步驗證方式:' -ForegroundColor White
Write-Host '   1. 重新開機' -ForegroundColor Gray
Write-Host '   2. 開 dxdiag,顯示卡分頁應顯示 NVIDIA + DDI 12' -ForegroundColor Gray
Write-Host '   3. 跑 GPU Caps Viewer / OpenGL 程式驗證' -ForegroundColor Gray
Write-Host '   4. 看 boot.log: C:\ProgramData\VM_NVFix\boot.log' -ForegroundColor Gray
Write-Host ''

$rb = Read-WithDefault -Prompt '要立即重新開機嗎? (Y/N)' -Default 'Y' -Seconds 5
if ($rb -match '^[Yy]') {
    W-Step '10 秒後重新開機... 按 Ctrl+C 取消'
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}
