# =========================================================
#  Host_Master_DriverOnly_v2.ps1
#  Hyper-V GPU-PV 直通 + 顯卡驅動複製 (廠牌無關版:NVIDIA / AMD 自動偵測,不搬遊戲)
#
#  基底 = Host_Master_DriverOnly_v1.1,GPU-PV 參數 / VHDX 掛載 / INF 補漏流程不變。
#
#  v2 (vs v1.1) - 唯一目標:v1.1 寫死 NVIDIA (nv*.inf_amd64_* 資料夾名 + nvoglv64.dll
#  判定 + nvlddmkm.sys 版本比對主機現用版本、只掃套件「頂層」檔案攤平、只補 NVIDIA
#  的 CUDA runtime)。v2 改成自動偵測顯卡廠牌,AMD 也能搬:
#    + 廠牌偵測:改讀 Msvm_PartitionableGpu 的 PNP 路徑解析 VEN_xxxx (10DE=NVIDIA/
#      1002=AMD/8086=Intel),而不是看主機裝了哪張顯示卡 —— 只有「可分割 GPU」那張
#      才是 GPU-PV 會用到的卡。VEN 抓不到或不支援 (含 Intel) 一律大聲 exit 1。
#    + 選套件:改成「內容含廠牌 marker 檔」判定,且遞迴掃描 (取代 v1.1 只認資料夾名
#      nv*.inf_amd64_* + 只看頂層 nvoglv64.dll)。AMD 的 amdkmdag.sys/amdxc64.dll 藏在
#      套件內的子資料夾 (如 B026373\),資料夾名也不是 amd*/ati* 開頭,只能靠內容判定。
#      主顯示套件 (含 DisplayMarker) 若有多包只留版本最新的一包;其餘含 marker 的
#      延伸套件 (OpenGL/Vulkan/元件) 全部納入 $copySet —— 這也連帶修正 v1.1 會把不
#      相關的 nv* 套件 (如音效驅動 nvhda/nvvad) 一併整包複製進 VM 的問題,v2 只搬
#      真正跟顯示相關的套件。
#    + 5b 攤平:改成對 $copySet 每包遞迴掃全部檔案,依 Get-ExeArch 讀 PE machine type
#      逐檔判 x86/x64/arm64 分流 (取代 v1.1「只看套件頂層 + 檔名含 32 猜測 32-bit」)。
#      AMD 的 atioglxx.dll 32-bit 版與 64-bit 版檔名完全相同、分放在不同子資料夾,
#      只能靠 PE 架構分流,不能靠檔名或路徑猜。
#    + 5b-2/5b-3 (補 CUDA runtime / 從 INF 解析補漏) 只在 NVIDIA 分支跑,語意與 v1.1
#      完全相同;AMD 的 OpenGL/Vulkan 已由 marker 套件涵蓋,不需要、也不跑這兩步。
#    + 5c 自我檢查:關鍵檔清單與版本比對改依 $VendorProfiles 各廠牌的
#      CheckFiles / VerCheckFiles 資料驅動 (取代 v1.1 寫死的 NVIDIA 檔名清單);版本
#      比對的「來源」改用攤平當下實際複製來源的紀錄 ($flatCopiedFrom),同名檔存在
#      於多個套件時 (如 AMD 的 amdxc64.dll 同時在兩包裡) 以實際落地 VM 的那份為準,
#      避免比對到錯的來源。
#    + -CleanOld 安全化:v1.1 清理用 nv*.dll / nv*.exe / nv*.sys 萬用字元;v2 改成
#      「HostDriverStore 資料夾遞迴含本廠牌 marker 才刪」+「攤平檔僅刪檔名有出現在
#      本次 $copySet 套件集合裡的」,不用 amd*/ati* 萬用字元盲刪 (ati* 前綴同時也是
#      舊 ATI 授權商標,範圍比 nv* 更容易誤中系統其他檔)。Protect 清單依廠牌區分
#      (NVIDIA: nvraid/nvstor(64);AMD: amdsata/amdxata/amdsbs,皆為 boot-start 儲存
#      驅動,不是本工具搬進去的,刪了有開不了機的風險) 一律不刪。
#    + -Preview 加印「主機端計畫」:偵測到的廠牌、顯示裝置與驅動版本、$copySet 清單
#      (套件名+marker+版本)、攤平會產生的檔案分流預覽 (只分類計數+取樣,不複製);
#      原有 VM 清單那段行為不變,一樣在動任何東西前 exit。
#    + 步驟 1~4 (VM 硬體設定 / Add-VMGpuPartitionAdapter)、步驟 6 (卸載 VHDX)、
#      helper 函式、-Preview 的 VM 清單、-CleanOld/-NoCleanOld 開關語意逐字沿用
#      v1.1。步驟 7 結尾的欄位/流程/exit code 邏輯逐字沿用,只把版本號與 NVIDIA
#      專屬的「下一步」文字改成依廠牌分支 (NVIDIA 分支文字與 v1.1 完全相同,新增
#      AMD 分支;exit code 判斷條件不變)。
#    + 新增 helper Get-ExeArch (讀 PE machine type 回 x86/x64/arm64;抄自本資料夾
#      Mesa_OneClick_v1.3.ps1 既有實作,v1.1 沒有這個函式,因 5b 攤平需要逐檔判架構
#      才新增)。
#
#  v1.1 - 只搬「主機現用版本」那一個顯示驅動套件 (完整說明見 v1.1 檔頭原文)
#  v1.7 - 多開友善:MMIO 1G/8G,GPU 配額 8%
#  v1.6 - 補搬 modern OpenGL / CUDA runtime 相依 DLL (5b-2 + 5b-3)
#  v1.3 - nvoglv64.dll 判定 GPU 驅動資料夾 + 攤平複製到 System32
# =========================================================
param(
    [string]$VMName = '',
    [switch]$Yes,
    [switch]$Preview,
    [switch]$CleanOld,
    [switch]$NoCleanOld
)

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# =========================================================
#  可調參數 - 改這裡就能調整資源分配
# =========================================================
# MMIO 配置 (給顯示卡驅動的 PCI BAR 位址空間)
#   單台用力跑: 3 / 32 (Host_Master 原值)
#   多開穩定 (4~8 台): 1 / 8   ← 預設,社群驗證
#   極限多開 (10+ 台): 0.5 / 4 (有閃退風險)
$MMIO_LOW_GB  = 1
$MMIO_HIGH_GB = 8

# GPU 配額百分比 (0~100,每台 VM 拿多少 % GPU 資源)
#   單台: 10
#   多開: 8   ← 預設,6 台共 48%,留 50% 給其他/系統
#   重壓: 5   (畫面會卡)
$GPU_QUOTA_PCT = 8
# =========================================================

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

# 互動詢問;-Yes 時一律回 True
function Ask-YN($prompt) {
    if ($Yes) { W-Info ("(-Yes) 自動同意: " + $prompt); return $true }
    $yn = Read-Host ($prompt + '(Y/N)')
    return ($yn -match '^[Yy]')
}

# 讀檔案版本成 [version] 物件;檔案不存在或讀不到回 $null
function Get-FileVer([string]$path) {
    if (-not $path) { return $null }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $vi = (Get-Item -LiteralPath $path).VersionInfo
        return [version]('{0}.{1}.{2}.{3}' -f $vi.FileMajorPart, $vi.FileMinorPart, $vi.FileBuildPart, $vi.FilePrivatePart)
    } catch { return $null }
}

# 讀 PE 檔頭 machine type 判斷架構 (v1.1 沒有這個 helper,v2 攤平分流需要;
# 實作抄自本資料夾 Mesa_OneClick_v1.3.ps1 既有的 Get-ExeArch,原樣沿用)
function Get-ExeArch {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $br = New-Object System.IO.BinaryReader($fs)
        try {
            $fs.Position = 0x3C
            $peOffset = $br.ReadInt32()
            if ($peOffset -lt 0 -or $peOffset -gt $fs.Length - 6) { return 'Unknown' }
            $fs.Position = $peOffset
            if ($br.ReadUInt32() -ne 0x4550) { return 'Unknown' }
            switch ($br.ReadUInt16()) {
                0x014c  { return 'x86' }
                0x8664  { return 'x64' }
                0xAA64  { return 'arm64' }
                default { return 'Unknown' }
            }
        } finally { $br.Close(); $fs.Close() }
    } catch { return 'Error' }
}

# =========================================================
#  廠牌設定表 (v2 新增) - 每個廠牌一份:
#    NameMatch     Win32_PnPSignedDriver DeviceName 比對用的關鍵字 regex
#    Markers       判定「這個 DriverStore 資料夾是顯示相關套件」的檔名集合
#    DisplayMarker 主顯示驅動代表檔;同一 DisplayMarker 出現在多個套件時只留版本最新的
#    Protect       -CleanOld 絕不刪的 Windows 內建檔 (boot-start 儲存驅動)
#    CheckFiles    5c 自我檢查用的關鍵檔清單 (Rel = VM 磁碟機根目錄起算的相對路徑)
#    VerCheckFiles 5c 版本比對用 (SrcKey = 攤平時記錄來源用的檔名 key,對應 $flatCopiedFrom)
# =========================================================
$VendorProfiles = @{
    '10DE' = @{
        Vendor        = 'NVIDIA'
        NameMatch     = 'NVIDIA|GeForce|RTX|GTX'
        Markers       = @('nvoglv64.dll')
        DisplayMarker = 'nvoglv64.dll'
        Protect       = @('nvraid.sys', 'nvstor.sys', 'nvstor64.sys')
        CheckFiles    = @(
            @{ Name = 'nvoglv64.dll (OpenGL ICD 64-bit)';   Rel = 'Windows\System32\nvoglv64.dll';          Critical = $true  }
            @{ Name = 'nvoglv32.dll (OpenGL ICD 32-bit)';   Rel = 'Windows\SysWOW64\nvoglv32.dll';          Critical = $false }
            @{ Name = 'nvlddmkm.sys (Kernel Mode Driver)';  Rel = 'Windows\System32\drivers\nvlddmkm.sys';  Critical = $true  }
            @{ Name = 'nvldumdx.dll (User Mode Driver)';    Rel = 'Windows\System32\nvldumdx.dll';          Critical = $true  }
            @{ Name = 'nvapi64.dll (NVAPI)';                Rel = 'Windows\System32\nvapi64.dll';           Critical = $false }
            @{ Name = 'nvcuda.dll (CUDA Driver API)';       Rel = 'Windows\System32\nvcuda.dll';            Critical = $true  }
            @{ Name = 'nvcompiler.dll (NVRTC)';             Rel = 'Windows\System32\nvcompiler.dll';        Critical = $true  }
            @{ Name = 'nvfatbinaryLoader.dll';              Rel = 'Windows\System32\nvfatbinaryLoader.dll'; Critical = $true  }
            @{ Name = 'nvptxJitCompiler.dll';               Rel = 'Windows\System32\nvptxJitCompiler.dll';  Critical = $true  }
        )
        VerCheckFiles = @(
            @{ Name = 'System32\drivers\nvlddmkm.sys'; VmRel = 'Windows\System32\drivers\nvlddmkm.sys'; SrcKey = 'nvlddmkm.sys' }
            @{ Name = 'System32\nvoglv64.dll';          VmRel = 'Windows\System32\nvoglv64.dll';          SrcKey = 'nvoglv64.dll' }
            @{ Name = 'System32\nvldumdx.dll';          VmRel = 'Windows\System32\nvldumdx.dll';          SrcKey = 'nvldumdx.dll' }
        )
    }
    '1002' = @{
        Vendor        = 'AMD'
        NameMatch     = 'Radeon|AMD|ATI'
        Markers       = @('amdkmdag.sys', 'atioglxx.dll', 'amdvlk64.dll', 'amdxc64.dll', 'atidxx64.dll', 'aticfx64.dll', 'atig6pxx.dll')
        DisplayMarker = 'amdkmdag.sys'
        # 攤平白名單 (對抗審查 finding 2):只把檔名以這些前綴開頭的 .dll/.exe/.sys 搬進
        # System32/SysWOW64/drivers,避免把套件裡萬一有的、與 Windows 系統檔同名的通用檔覆蓋掉。
        # AMD 顯示/GL/Vulkan 需要落地的檔全是 amd*/ati* 命名 (amdkmdag/amdxc64/amdvlk64/atioglxx/
        # atidxx64/aticfx64),白名單不會漏。NVIDIA profile 刻意不設此鍵 → 沿用 v1.1 全攤平 (已實機驗證)。
        FlattenPrefixes = @('amd', 'ati')
        Protect       = @('amdsata.sys', 'amdxata.sys', 'amdsbs.sys')
        CheckFiles    = @(
            @{ Name = 'amdkmdag.sys (Kernel Mode Driver)'; Rel = 'Windows\System32\drivers\amdkmdag.sys'; Critical = $true  }
            @{ Name = 'amdxc64.dll (Display UMD)';         Rel = 'Windows\System32\amdxc64.dll';          Critical = $true  }
            @{ Name = 'atioglxx.dll (OpenGL ICD)';         Rel = 'Windows\System32\atioglxx.dll';         Critical = $true  }
            @{ Name = 'amdvlk64.dll (Vulkan ICD)';         Rel = 'Windows\System32\amdvlk64.dll';         Critical = $true  }
            @{ Name = 'atidxx64.dll (D3D UMD)';            Rel = 'Windows\System32\atidxx64.dll';         Critical = $false }
            @{ Name = 'aticfx64.dll (D3D CFX)';            Rel = 'Windows\System32\aticfx64.dll';         Critical = $false }
        )
        VerCheckFiles = @(
            @{ Name = 'System32\drivers\amdkmdag.sys'; VmRel = 'Windows\System32\drivers\amdkmdag.sys'; SrcKey = 'amdkmdag.sys' }
            @{ Name = 'System32\amdxc64.dll';           VmRel = 'Windows\System32\amdxc64.dll';           SrcKey = 'amdxc64.dll' }
            @{ Name = 'System32\atioglxx.dll';          VmRel = 'Windows\System32\atioglxx.dll';          SrcKey = 'atioglxx.dll' }
        )
    }
}

W-Title 'GPU-PV 直通 + 驅動複製工具 DriverOnly v2 (廠牌無關:NVIDIA / AMD 自動偵測,不搬遊戲)'
W-Info ("MMIO Low/High = ${MMIO_LOW_GB}GB / ${MMIO_HIGH_GB}GB  |  GPU 配額 = ${GPU_QUOTA_PCT}%")
if ($Preview) { W-Warn '-Preview 模式:只掃描主機與 VM 清單,不做任何變更' }
if ($CleanOld -and $NoCleanOld) {
    W-Err '-CleanOld 與 -NoCleanOld 不能同時使用'
    exit 1
}
if ($CleanOld)   { W-Info '-CleanOld:搬運前會先清掉 VM 內既有的本廠牌顯示驅動檔 (乾淨重裝)' }
if ($NoCleanOld) { W-Info '-NoCleanOld:不清舊檔,只覆蓋同名檔' }

# =========================================================
#  0. 預檢
# =========================================================
W-Step '環境檢查'

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    W-Err '找不到 Hyper-V 模組,這台電腦可能不是 Hyper-V 主機'
    exit 1
}
Import-Module Hyper-V -ErrorAction SilentlyContinue
W-OK 'Hyper-V 模組 OK'

# ---------------------------------------------------------
#  0a. 廠牌偵測 (v2 新增,取代 v1.1 寫死 NVIDIA)
#  用 Msvm_PartitionableGpu 的 PNP 路徑抓 VEN_xxxx 判斷廠牌 —— 只有「可分割 GPU」
#  那張才是 GPU-PV 會實際用到的卡,不是看主機裝了哪張顯示卡。
# ---------------------------------------------------------
W-Step '偵測可分割 GPU 廠牌'
$vendorIdMap = @{ '10DE' = 'NVIDIA'; '1002' = 'AMD'; '8086' = 'Intel' }
$pgpus = @()
try {
    $pgpus = @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_PartitionableGpu -ErrorAction Stop)
} catch {
    W-Err ('讀不到 Msvm_PartitionableGpu (需要系統管理員權限 / 主機可能未啟用 GPU-PV): ' + $_.Exception.Message)
    exit 1
}
if ($pgpus.Count -eq 0) {
    W-Err '找不到任何可分割 GPU (Msvm_PartitionableGpu 回傳空);主機顯示卡驅動可能不支援 GPU-PV 或未安裝'
    exit 1
}
if ($pgpus.Count -gt 1) {
    W-Warn ('主機有 ' + $pgpus.Count + ' 張可分割 GPU,本工具只處理第一張:')
    foreach ($pg in $pgpus) { W-Info ('  ' + $pg.Name) }
}
$pgpu = $pgpus[0]
$venMatch = [regex]::Match($pgpu.Name, 'VEN_([0-9A-Fa-f]{4})')
if (-not $venMatch.Success) {
    W-Err ('無法從 PNP 路徑解析 VEN_xxxx: ' + $pgpu.Name)
    exit 1
}
$venId = $venMatch.Groups[1].Value.ToUpper()
if (-not $vendorIdMap.ContainsKey($venId)) {
    W-Err ('無法辨識的顯卡廠牌 VEN_' + $venId + ' (' + $pgpu.Name + ')')
    exit 1
}
$vendorName = $vendorIdMap[$venId]
if (-not $VendorProfiles.ContainsKey($venId)) {
    W-Err ('偵測到 ' + $vendorName + ' 顯卡 (VEN_' + $venId + '),但本工具目前不支援此廠牌 (只支援 NVIDIA / AMD)')
    exit 1
}
$vp = $VendorProfiles[$venId]
W-OK ('可分割 GPU 廠牌: ' + $vendorName + '  (' + $pgpu.Name + ')')

# 顯示裝置與主機現用驅動版本 (改用 Win32_PnPSignedDriver 取 DriverVersion/InfName)
$hostGpu = $null
$hostVer = $null
try {
    $hostGpu = Get-CimInstance Win32_PnPSignedDriver | Where-Object { $_.DeviceClass -eq 'DISPLAY' -and $_.DeviceName -match $vp.NameMatch } | Select-Object -First 1
    if ($hostGpu -and $hostGpu.DriverVersion) { $hostVer = [version]$hostGpu.DriverVersion }
} catch {}
if ($hostGpu) {
    W-OK ('主機顯示裝置: ' + $hostGpu.DeviceName + '  現用驅動版本: ' + $hostGpu.DriverVersion + '  (' + $hostGpu.InfName + ')')
} else {
    W-Warn ('主機沒有回報符合 ' + $vendorName + ' 的顯示裝置 (Win32_PnPSignedDriver),無法比對現用版本')
}

# ---------------------------------------------------------
#  0b. 掃 DriverStore,選出要搬的顯示驅動套件 (v2:廠牌 marker 判定 + 遞迴,取代
#  v1.1「只認 nv*.inf_amd64_* 資料夾名 + 只掃頂層」的作法 —— AMD 主套件的關鍵檔在
#  子資料夾裡 (如 B026373\amdkmdag.sys),資料夾名也不是 amd*/ati* 開頭,只能靠內容判定)
# ---------------------------------------------------------
W-Step ('搜尋 ' + $vendorName + ' 顯示驅動套件 (DriverStore,遞迴比對 marker 檔)')
$repoRoot = "$env:WinDir\System32\DriverStore\FileRepository"
$allPkgFolders = @(Get-ChildItem $repoRoot -Directory -ErrorAction SilentlyContinue)
$foundPkgs = @()
foreach ($folder in $allPkgFolders) {
    $filesHere = @(Get-ChildItem $folder.FullName -Recurse -File -ErrorAction SilentlyContinue)
    if ($filesHere.Count -eq 0) { continue }
    $fileNamesHere = @($filesHere | ForEach-Object { $_.Name })
    $markersHere = @($vp.Markers | Where-Object { $fileNamesHere -contains $_ })
    if ($markersHere.Count -eq 0) { continue }

    $hasDisp = ($markersHere -contains $vp.DisplayMarker)
    $dispVer = $null
    if ($hasDisp) {
        $dm = $filesHere | Where-Object { $_.Name -eq $vp.DisplayMarker } | Select-Object -First 1
        if ($dm) { $dispVer = Get-FileVer $dm.FullName }
    }
    $folder | Add-Member -NotePropertyName MarkersFound -NotePropertyValue $markersHere -Force
    $folder | Add-Member -NotePropertyName HasDisplay   -NotePropertyValue $hasDisp     -Force
    $folder | Add-Member -NotePropertyName DisplayVer   -NotePropertyValue $dispVer     -Force
    $foundPkgs += $folder
}
if ($foundPkgs.Count -eq 0) {
    W-Err ('在 DriverStore 找不到任何含 ' + $vendorName + ' marker 檔的套件 (' + ($vp.Markers -join ', ') + ')')
    W-Info ('請先在主機安裝 ' + $vendorName + ' 正式驅動再跑本工具')
    exit 1
}
W-OK ('找到候選套件: ' + $foundPkgs.Count + ' 個')
foreach ($p in $foundPkgs) {
    $tag = if ($p.HasDisplay) { ' [主顯示套件 ' + $p.DisplayVer + ']' } else { '' }
    W-Info ('  ' + $p.Name + '  marker: ' + ($p.MarkersFound -join ', ') + $tag)
}

# 去重:含 DisplayMarker 的套件若有多包,只留版本最新的一包 (濾掉殘留舊驅動);
# 其餘含 marker 但不含 DisplayMarker 的套件 (OpenGL/Vulkan/延伸元件) 全部納入
$displayPkgs = @($foundPkgs | Where-Object { $_.HasDisplay })
$otherPkgs   = @($foundPkgs | Where-Object { -not $_.HasDisplay })
if ($displayPkgs.Count -eq 0) {
    W-Err ('找不到含主顯示驅動 marker (' + $vp.DisplayMarker + ') 的套件,無法判定要搬哪個版本')
    exit 1
}
$withVer = @($displayPkgs | Where-Object { $_.DisplayVer })
if ($withVer.Count -eq 0) {
    W-Err ('所有含 ' + $vp.DisplayMarker + ' 的套件都讀不到版本,無法判定最新版')
    exit 1
}
$chosenDisplay = $withVer | Sort-Object DisplayVer -Descending | Select-Object -First 1
W-OK ('選用主顯示套件: ' + $chosenDisplay.Name + '  (版本 ' + $chosenDisplay.DisplayVer + ')')
$skippedDisplay = @($displayPkgs | Where-Object { $_.Name -ne $chosenDisplay.Name })
foreach ($s in $skippedDisplay) {
    W-Info ('  略過舊版主顯示套件: ' + $s.Name + '  [' + $s.DisplayVer + ']')
}
if ($hostVer -and $chosenDisplay.DisplayVer -and ($hostVer -ne $chosenDisplay.DisplayVer)) {
    W-Warn ('選用套件版本 ' + $chosenDisplay.DisplayVer + ' 與主機現用版本 ' + $hostVer + ' 不同,搬進 VM 後可能與主機不符,請先確認主機驅動狀態')
}

$copySet = @()
$copySet += $chosenDisplay
$copySet += $otherPkgs
W-OK ('本次要搬的套件: ' + $copySet.Count + ' 個 (1 個主顯示 + ' + $otherPkgs.Count + ' 個延伸元件)')
foreach ($cs in $copySet) {
    $verTxt = if ($cs.HasDisplay) { [string]$cs.DisplayVer } else { '(延伸元件,無版本比對)' }
    W-Info ('  ' + $cs.Name + '  ' + $verTxt)
}

# 主機可分割 GPU (需要系統管理員;讀不到只警告) —— 與 0a 的 Msvm_PartitionableGpu
# 用途不同,這裡是 v1.1 原有的診斷資訊 (分區上限/VRAM),逐字沿用
W-Step '主機可分割 GPU'
$hostPGpus = @()
try {
    $hostPGpus = @(Get-VMHostPartitionableGpu -ErrorAction Stop)
    W-OK ('主機可分割 GPU: ' + $hostPGpus.Count + ' 張')
    foreach ($g in $hostPGpus) {
        W-Info ('  ' + $g.Name)
        W-Info ('    分區上限 PartitionCount: ' + $g.PartitionCount + '  VRAM 可用/總: ' + $g.AvailableVRAM + ' / ' + $g.TotalVRAM + '  (單位 1e9 = 100%)')
    }
    if ($hostPGpus.Count -eq 0) {
        W-Warn '主機沒有任何可分割 GPU (驅動不支援 GPU-PV 或未安裝),後面加分區會失敗'
    }
} catch {
    W-Warn ('讀不到 Get-VMHostPartitionableGpu: ' + $_.Exception.Message)
}

# =========================================================
#  -Preview:印主機端計畫 + 列出 Gen2 VM 與分區介面卡數就結束,不做任何變更
# =========================================================
if ($Preview) {
    W-Title '-Preview:主機端計畫 (唯讀,未掛載 VHDX、未變更任何 VM)'
    W-Info ('偵測廠牌: ' + $vendorName + '  (VEN_' + $venId + ')')
    if ($hostGpu) {
        W-Info ('顯示裝置: ' + $hostGpu.DeviceName + '  驅動版本: ' + $hostGpu.DriverVersion + '  (' + $hostGpu.InfName + ')')
    } else {
        W-Warn '主機沒有回報符合廠牌的顯示裝置'
    }
    W-Info ('要搬的套件 (' + $copySet.Count + ' 個):')
    foreach ($cs in $copySet) {
        $verTxt = if ($cs.HasDisplay) { [string]$cs.DisplayVer } else { '(延伸元件,無版本比對)' }
        W-Info ('  ' + $cs.Name + '  marker: ' + ($cs.MarkersFound -join ', ') + '  ' + $verTxt)
    }

    # 模擬攤平分流 (只分類計數+取樣,不複製、不觸碰 VM)
    W-Info '攤平分流預覽 (只計數與取樣,不複製):'
    $pvX64 = New-Object System.Collections.Generic.List[string]
    $pvX86 = New-Object System.Collections.Generic.List[string]
    $pvSys = New-Object System.Collections.Generic.List[string]
    $pvUnknown = 0
    $pvPrefixes = @()
    if ($vp.ContainsKey('FlattenPrefixes')) { $pvPrefixes = @($vp.FlattenPrefixes | ForEach-Object { $_.ToLower() }) }
    foreach ($folder in $copySet) {
        $files = @(Get-ChildItem $folder.FullName -Recurse -File -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $ext = $f.Extension.ToLower()
            if ($ext -ne '.sys' -and $ext -ne '.dll' -and $ext -ne '.exe') { continue }
            if ($pvPrefixes.Count -gt 0) {
                $nl = $f.Name.ToLower(); $okPre = $false
                foreach ($pre in $pvPrefixes) { if ($nl.StartsWith($pre)) { $okPre = $true; break } }
                if (-not $okPre) { continue }
            }
            if ($ext -eq '.sys') {
                $pvSys.Add($f.Name)
            } else {
                $arch = Get-ExeArch $f.FullName
                if ($arch -eq 'x86') {
                    $pvX86.Add($f.Name)
                } else {
                    if ($arch -ne 'x64') { $pvUnknown++ }
                    $pvX64.Add($f.Name)
                }
            }
        }
    }
    $sample = 5
    W-Info ('  x64 DLL/EXE -> System32        : ' + $pvX64.Count + ' 個  例: ' + (($pvX64 | Select-Object -First $sample) -join ', '))
    W-Info ('  x86 DLL     -> SysWOW64        : ' + $pvX86.Count + ' 個  例: ' + (($pvX86 | Select-Object -First $sample) -join ', '))
    W-Info ('  SYS         -> System32\drivers: ' + $pvSys.Count + ' 個  例: ' + (($pvSys | Select-Object -First $sample) -join ', '))
    if ($pvUnknown -gt 0) {
        W-Warn ('  其中 ' + $pvUnknown + ' 個無法判定 PE 架構,計畫預設當 x64 放 System32')
    }

    W-Title '-Preview:VM 清單 (GPU 欄 = 現有 GPU 分區介面卡數)'
    try {
        $vmsP = @(Get-VM -ErrorAction Stop | Where-Object { $_.Generation -eq 2 } | Sort-Object Name)
        if ($vmsP.Count -eq 0) { W-Warn '找不到 Generation 2 VM' }
        foreach ($v in $vmsP) {
            $n = @(Get-VMGpuPartitionAdapter -VMName $v.Name -ErrorAction SilentlyContinue).Count
            W-Info ('  {0,-30} ({1})  GPU: {2}' -f $v.Name, $v.State, $n)
            if ($n -gt 1) {
                W-Warn ('    ^ ' + $v.Name + ' 掛了 ' + $n + ' 個介面卡 (VM 內會看到重複顯示卡),正式跑會清成 1 個')
            }
        }
    } catch {
        W-Warn ('讀不到 VM 清單 (需要系統管理員): ' + $_.Exception.Message)
    }
    Write-Host ''
    W-OK '預覽結束,未變更任何東西'
    exit 0
}

# =========================================================
#  1. 選擇目標 VM
# =========================================================
if ($VMName) {
    # 用精確比對而不是 Get-VM -Name (後者吃萬用字元,名稱含 * ? [ 會配到多台,
    # 之後的關機/掛載/加分區就會對著陣列亂做)
    $vmHits = @(Get-VM -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $VMName })
    if ($vmHits.Count -ne 1) {
        W-Err ('-VMName "' + $VMName + '" 對到 ' + $vmHits.Count + ' 台 VM (必須剛好 1 台)')
        exit 1
    }
    $vm = $vmHits[0]
    if ($vm.Generation -ne 2) {
        W-Err ('VM ' + $VMName + ' 不是 Generation 2,GPU-PV 需要 Gen 2 VM')
        exit 1
    }
} else {
    W-Step '選擇目標 VM'
    $vms = @(Get-VM | Where-Object { $_.Generation -eq 2 } | Sort-Object Name)
    if ($vms.Count -eq 0) {
        W-Err '找不到 Generation 2 VM。GPU-PV 需要 Gen 2 VM。'
        exit 1
    }

    Write-Host ''
    Write-Host 'Gen 2 VM 清單 (GPU 欄 = 現有 GPU 分區介面卡數):' -ForegroundColor White
    for ($i = 0; $i -lt $vms.Count; $i++) {
        $v = $vms[$i]
        $gpuN = @(Get-VMGpuPartitionAdapter -VMName $v.Name -ErrorAction SilentlyContinue).Count
        $color = if ($v.State -eq 'Running') { 'Green' } else { 'Gray' }
        Write-Host ('  [{0}] {1,-30} ({2})  GPU: {3}' -f ($i + 1), $v.Name, $v.State, $gpuN) -ForegroundColor $color
    }
    Write-Host ''
    $raw = Read-Host '請輸入 VM 編號'
    if (-not ($raw -as [int]) -or [int]$raw -lt 1 -or [int]$raw -gt $vms.Count) {
        W-Err '無效的編號'
        exit 1
    }
    $vm = $vms[[int]$raw - 1]
}
$vmName = $vm.Name
W-OK ('已選擇: ' + $vmName)

# =========================================================
#  2. 確認 VM 已關機 (GPU-PV 設定與掛載 VHDX 都需要)
# =========================================================
if ($vm.State -ne 'Off') {
    Write-Host ''
    W-Warn ('VM 目前狀態: ' + $vm.State + '  本操作需要 VM 關機。')
    if (Ask-YN '要立即關機嗎?') {
        W-Step ('關閉 ' + $vmName)
        Stop-VM -Name $vmName -Force -ErrorAction Stop
        W-OK '已關機'
    } else {
        W-Err '取消操作'
        exit 1
    }
}

# 檢查 checkpoint - GPU-PV + checkpoint 會衝突
$cps = @(Get-VMCheckpoint -VMName $vmName -ErrorAction SilentlyContinue)
if ($cps.Count -gt 0) {
    Write-Host ''
    W-Warn ('此 VM 有 ' + $cps.Count + ' 個檢查點。GPU-PV 建議關閉檢查點並刪除現有檢查點。')
    if (Ask-YN '要刪除所有檢查點嗎?') {
        $cps | ForEach-Object {
            W-Step ('刪除檢查點: ' + $_.Name)
            Remove-VMCheckpoint -VMName $vmName -Name $_.Name -Confirm:$false
        }
        W-Step '等待檢查點合併...'
        do {
            Start-Sleep -Seconds 3
            $status = (Get-VM -Name $vmName).Status
        } while ($status -match 'Merging|Merge|Saving')
        W-OK '檢查點清理完成'
    }
}

# =========================================================
#  3. 配置 VM 硬體以支援 GPU-PV
# =========================================================
W-Title '配置 VM 硬體'

# CPU 核心數檢查
$currentCores = (Get-VMProcessor -VMName $vmName).Count
$hostLogicalCpu = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
W-Info ('VM 目前 CPU 核心: ' + $currentCores + ' 核 (主機共 ' + $hostLogicalCpu + ' 邏輯核心)')
if ($currentCores -lt 4) {
    Write-Host ''
    Write-Host ('[!] VM 只有 ' + $currentCores + ' 核,3D 應用可能卡頓。建議 4 核起跳。') -ForegroundColor Yellow
    if (Ask-YN '要立即調整為 4 核嗎?') {
        try {
            Set-VMProcessor -VMName $vmName -Count 4 -ErrorAction Stop
            W-OK 'CPU 已設為 4 核'
        } catch { W-Err ('CPU 設定失敗: ' + $_.Exception.Message) }
    }
}

W-Step '停用動態記憶體'
try {
    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -ErrorAction Stop
    W-OK '動態記憶體已停用'
} catch { W-Err ('失敗: ' + $_.Exception.Message) }

W-Step '停用自動檢查點'
try {
    Set-VM -Name $vmName -AutomaticCheckpointsEnabled $false -CheckpointType Disabled -ErrorAction Stop
    W-OK '檢查點已關閉'
} catch { W-Err ('失敗: ' + $_.Exception.Message) }

W-Step '設定自動停機動作為關機'
try {
    Set-VM -Name $vmName -AutomaticStopAction TurnOff -ErrorAction Stop
    W-OK 'AutomaticStopAction = TurnOff'
} catch { W-Err ('失敗: ' + $_.Exception.Message) }

W-Step "設定 GPU-PV 必要參數 (MMIO ${MMIO_LOW_GB}G/${MMIO_HIGH_GB}G + Cache)"
try {
    Set-VM -Name $vmName -GuestControlledCacheTypes $true
    Set-VM -Name $vmName -LowMemoryMappedIoSpace ([uint64]($MMIO_LOW_GB * 1GB))
    Set-VM -Name $vmName -HighMemoryMappedIoSpace ([uint64]($MMIO_HIGH_GB * 1GB))
    W-OK "GuestControlledCacheTypes=True, LowMMIO=${MMIO_LOW_GB}GB, HighMMIO=${MMIO_HIGH_GB}GB"
} catch { W-Err ('失敗: ' + $_.Exception.Message) }

$vmMem = Get-VMMemory -VMName $vmName
W-Info ('VM 記憶體: {0:N0} MB (Startup), 動態記憶體: {1}' -f `
    ($vmMem.Startup / 1MB), $vmMem.DynamicMemoryEnabled)
if (($vmMem.Startup / 1GB) -lt 4) {
    W-Warn '建議 VM 記憶體至少 4GB 以上,GPU-PV 才穩定'
}

# =========================================================
#  4. 重新加入 GPU 分區介面卡 (清掉重複掛載,只留 1 個)
# =========================================================
W-Step '重新加入 GPU 分區介面卡'
try {
    $existing = @(Get-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue)
    W-Info ('VM 現有介面卡: ' + $existing.Count + ' 個;主機可分割 GPU: ' + $hostPGpus.Count + ' 張')
    if ($existing.Count -gt 1) {
        W-Warn ('介面卡數 > 1,VM 內會看到重複的顯示卡 (兩張同名卡),現在清成 1 個')
    }
    if ($existing.Count -gt 0) {
        W-Info ('移除既有 ' + $existing.Count + ' 個 GPU 分區')
        $existing | ForEach-Object { Remove-VMGpuPartitionAdapter -VMName $vmName -AdapterId $_.Id }
    }
    Add-VMGpuPartitionAdapter -VMName $vmName -ErrorAction Stop
    W-OK 'GPU 分區介面卡已加入'

    $gpuAdapter = Get-VMGpuPartitionAdapter -VMName $vmName | Select-Object -First 1
    if ($gpuAdapter) {
        # 把百分比轉成 0~1,000,000,000 區間的整數
        $quotaMax = [uint64]($GPU_QUOTA_PCT * 10000000)
        $quotaMin = [uint64]($quotaMax * 0.8)  # Min 設為 Max 的 80% (留彈性)
        $quotaSet = $false
        try {
            Set-VMGpuPartitionAdapter -VMName $vmName `
                -MinPartitionVRAM $quotaMin -MaxPartitionVRAM $quotaMax -OptimalPartitionVRAM $quotaMax `
                -MinPartitionEncode $quotaMin -MaxPartitionEncode $quotaMax -OptimalPartitionEncode $quotaMax `
                -MinPartitionDecode $quotaMin -MaxPartitionDecode $quotaMax -OptimalPartitionDecode $quotaMax `
                -MinPartitionCompute $quotaMin -MaxPartitionCompute $quotaMax -OptimalPartitionCompute $quotaMax `
                -ErrorAction Stop
            $quotaSet = $true
        } catch {
            W-Warn ('完整配額 (VRAM+Encode+Decode+Compute) 寫入失敗: ' + $_.Exception.Message)
            W-Info '改只寫 VRAM 配額再試一次'
            try {
                Set-VMGpuPartitionAdapter -VMName $vmName `
                    -MinPartitionVRAM $quotaMin -MaxPartitionVRAM $quotaMax -OptimalPartitionVRAM $quotaMax `
                    -ErrorAction Stop
                $quotaSet = $true
            } catch {
                W-Err ('配額寫入失敗 (介面卡已加入,配額維持預設值): ' + $_.Exception.Message)
            }
        }
        if ($quotaSet) {
            W-OK ("GPU 分區配額已設定 ($GPU_QUOTA_PCT% per VM)")
        }
        $chk = Get-VMGpuPartitionAdapter -VMName $vmName | Select-Object -First 1
        W-Info ('讀回: MinPartitionVRAM=' + $chk.MinPartitionVRAM + '  MaxPartitionVRAM=' + $chk.MaxPartitionVRAM + '  OptimalPartitionVRAM=' + $chk.OptimalPartitionVRAM)
    }

    $afterN = @(Get-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue).Count
    if ($afterN -eq 1) {
        W-OK '介面卡數 = 1'
    } else {
        W-Err ('介面卡數應為 1,實際 ' + $afterN)
    }
} catch { W-Err ('失敗: ' + $_.Exception.Message) }

# =========================================================
#  5. 掛載 VHDX 並複製驅動
# =========================================================
W-Title 'VHDX 掛載 + 驅動複製'

$hdd = Get-VMHardDiskDrive -VMName $vmName | Select-Object -First 1
if (-not $hdd) {
    W-Err '這個 VM 沒有掛 VHDX,無法複製驅動'
    exit 1
}
$vhdPath = $hdd.Path
W-Info ('VHDX 路徑: ' + $vhdPath)

W-Step '掛載 VHDX'
$driveLetter = $null
$mountedDisk = $null
$vmDrive = $null
try {
    $mountedDisk = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
    Start-Sleep -Seconds 2
    $parts = @(Get-Partition -DiskNumber $mountedDisk.DiskNumber | Where-Object { $_.Type -eq 'Basic' -or $_.Type -eq 'IFS' -or $_.Size -gt 10GB } | Sort-Object Size -Descending)
    if ($parts.Count -eq 0) {
        throw '找不到可掛載的分區'
    }
    $sysPart = $parts[0]
    if (-not $sysPart.DriveLetter) {
        Add-PartitionAccessPath -DiskNumber $mountedDisk.DiskNumber -PartitionNumber $sysPart.PartitionNumber -AssignDriveLetter
        Start-Sleep -Seconds 1
        $sysPart = Get-Partition -DiskNumber $mountedDisk.DiskNumber -PartitionNumber $sysPart.PartitionNumber
    }
    $driveLetter = $sysPart.DriveLetter
    $vmDrive = $driveLetter + ':'
    W-OK ('VHDX 已掛載到 ' + $vmDrive)

    if (-not (Test-Path (Join-Path $vmDrive 'Windows\System32'))) {
        throw ('找不到 ' + $vmDrive + '\Windows\System32,這個 VHDX 可能不是 Windows 系統碟')
    }
} catch {
    W-Err ('掛載失敗: ' + $_.Exception.Message)
    if ($mountedDisk) { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue }
    exit 1
}

# ---------------------------------------------------------
#  5-pre. (可選 -CleanOld) 清掉 VM 內既有的本廠牌驅動檔,再重搬 = 乾淨重裝
#  v2 清理範圍改用 marker/檔名集合判定 (取代 v1.1 用 nv*/nv*.sys 萬用字元盲刪):
#    - HostDriverStore\FileRepository 內「資料夾遞迴含本廠牌任一 marker」才刪
#    - System32 / SysWOW64 / drivers 攤平檔,只刪「檔名有出現在本次 $copySet 套件裡」的
#  Protect 清單 (boot-start 儲存驅動) 一律跳過保留,不是本工具搬進去的、刪了有開不了機風險
# ---------------------------------------------------------
function Remove-OldVendorFiles([string]$root, $vendorProfile, $copySetForClean) {
    $protectedSys = @($vendorProfile.Protect | ForEach-Object { $_.ToLower() })
    $result = [ordered]@{ Folders = 0; Files = 0; Skipped = 0; Failed = 0 }

    # HostDriverStore:資料夾遞迴含本廠牌任一 marker 才刪 (避免誤刪別的廠牌/系統套件)
    $hds = Join-Path $root 'Windows\System32\HostDriverStore\FileRepository'
    if (Test-Path $hds) {
        foreach ($dirItem in @(Get-ChildItem $hds -Directory -ErrorAction SilentlyContinue)) {
            $innerNames = @(Get-ChildItem $dirItem.FullName -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            $hit = @($vendorProfile.Markers | Where-Object { $innerNames -contains $_ })
            if ($hit.Count -eq 0) { continue }
            try {
                Remove-Item -LiteralPath $dirItem.FullName -Recurse -Force -ErrorAction Stop
                $result.Folders++
                W-Info ('  刪除套件資料夾: ' + $dirItem.Name)
            } catch {
                $result.Failed++
                W-Warn ('  刪不掉資料夾: ' + $dirItem.Name + ' - ' + $_.Exception.Message)
            }
        }
    }

    # 攤平檔:只刪「檔名有出現在本次來源套件集合裡」的那些 (即本工具會裝的檔),
    # System32 / SysWOW64 / drivers 各自比對;Protect 清單一律跳過保留
    $ourFileNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($pkg in $copySetForClean) {
        Get-ChildItem $pkg.FullName -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { [void]$ourFileNames.Add($_.Name) }
    }
    $targets = @(
        (Join-Path $root 'Windows\System32')
        (Join-Path $root 'Windows\SysWOW64')
        (Join-Path $root 'Windows\System32\drivers')
    )
    foreach ($dir in $targets) {
        if (-not (Test-Path $dir)) { continue }
        foreach ($fileItem in @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue)) {
            if (-not $ourFileNames.Contains($fileItem.Name)) { continue }
            if ($protectedSys -contains $fileItem.Name.ToLower()) {
                $result.Skipped++
                W-Info ('  保留內建驅動: ' + $fileItem.FullName)
                continue
            }
            try {
                Remove-Item -LiteralPath $fileItem.FullName -Force -ErrorAction Stop
                $result.Files++
            } catch {
                $result.Failed++
                W-Warn ('  刪不掉: ' + $fileItem.FullName + ' - ' + $_.Exception.Message)
            }
        }
    }
    return $result
}

$doClean = $false
if ($CleanOld) {
    $doClean = $true
} elseif ($NoCleanOld) {
    $doClean = $false
} else {
    Write-Host ''
    W-Warn ('可以先清掉 VM 內既有的 ' + $vendorName + ' 驅動檔再重搬 (乾淨重裝):')
    W-Info '  - HostDriverStore\FileRepository 內含本廠牌 marker 的套件整包'
    W-Info '  - System32 / SysWOW64 / drivers 攤平檔,只清本次會搬的檔名集合 (不用萬用字元)'
    W-Info ('  - Windows 內建保護檔一律保留: ' + ($vp.Protect -join ', '))
    W-Info '換過顯示卡、或 VM 內曾看到兩張同名卡的機器,建議清。'
    $doClean = Ask-YN '要先清掉舊驅動檔嗎?'
}
if ($doClean) {
    W-Step ('清除 VM 內既有 ' + $vendorName + ' 驅動檔 (-CleanOld)')
    try {
        $cr = Remove-OldVendorFiles $vmDrive $vp $copySet
        W-OK ('已刪除 ' + $cr.Folders + ' 個 HostDriverStore 套件資料夾、' + $cr.Files + ' 個攤平檔;保留內建 ' + $cr.Skipped + ' 個;失敗 ' + $cr.Failed + ' 個')
        if ($cr.Failed -gt 0) {
            W-Warn '有東西刪不掉 (可能被鎖定)。後面複製會覆蓋同名檔,殘留只會是新套件沒有的舊檔名'
        }
    } catch {
        W-Err ('清除失敗: ' + $_.Exception.Message + ';繼續搬運 (只覆蓋同名檔)')
    }
} else {
    W-Info '略過清除舊驅動檔 (只覆蓋同名檔)'
}

# ---------------------------------------------------------
#  5a. HostDriverStore 整包複製 ($copySet = 主顯示套件 + 延伸元件套件)
# ---------------------------------------------------------
$destDriverRoot = Join-Path $vmDrive 'Windows\System32\HostDriverStore\FileRepository'
$hdsOK = 0
$hdsFail = 0
$hdsFailNames = @()
try {
    if (-not (Test-Path $destDriverRoot)) {
        New-Item -Path $destDriverRoot -ItemType Directory -Force | Out-Null
    }
} catch {
    W-Err ('建立 HostDriverStore 目錄失敗: ' + $_.Exception.Message)
}

# 逐資料夾 try/catch:一個失敗不能讓後面的全部略過
# (-CleanOld 之後尤其致命:舊的已經清掉,新的沒進去,VM 開機就沒驅動)
foreach ($folder in $copySet) {
    $destFolder = Join-Path $destDriverRoot $folder.Name
    W-Step ('複製 DriverStore: ' + $folder.Name)
    try {
        if (Test-Path $destFolder) {
            Remove-Item $destFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path $folder.FullName -Destination $destFolder -Recurse -Force -ErrorAction Stop
        $hdsOK++
    } catch {
        $hdsFail++
        $hdsFailNames += $folder.Name
        W-Err ('  複製失敗: ' + $folder.Name + ' - ' + $_.Exception.Message)
    }
}
if ($hdsFail -eq 0) {
    W-OK ('HostDriverStore 已複製 ' + $hdsOK + ' 個資料夾')
} else {
    W-Err ('HostDriverStore 複製: 成功 ' + $hdsOK + ' 個 / 失敗 ' + $hdsFail + ' 個 (' + ($hdsFailNames -join ', ') + ')')
    if ($hdsFailNames -contains $chosenDisplay.Name) {
        W-Err '  失敗的包含選中的主顯示套件,VM 開機後 GPU 一定不能用'
    }
    W-Err '  結束時會回 exit 1;請關掉佔用 VHDX 的程式後重跑本工具'
}

# ---------------------------------------------------------
#  5b. 攤平複製到 System32 / SysWOW64 / drivers
#  v2 對 $copySet 每包「遞迴」掃檔 (AMD 主套件的檔在子資料夾如 B026373\ 裡),逐檔用
#  Get-ExeArch 讀 PE machine type 判架構分流 (AMD 的 atioglxx.dll 32/64 位同檔名、分放不同
#  子資料夾,只能靠 PE 判)。兩項強化 (對抗審查 finding 1/2):
#   ① 先建「攤平計畫」:key = 檔名+目的地,同 key 只留版本最新的來源。消除「同名檔 (如
#      amdxc64.dll 同時在主套件與延伸套件) 依套件列舉順序後者蓋前者」的不確定性;x64/x86
#      同名檔目的地不同、key 不同,兩份都會保留。
#   ② FlattenPrefixes 白名單 (見 $VendorProfiles):AMD 只攤平 amd*/ati* 檔,避免把套件內
#      萬一有的、與 Windows 系統檔同名的通用檔覆蓋掉。NVIDIA 不設前綴 → 沿用 v1.1 全攤平。
# ---------------------------------------------------------
W-Step ('攤平複製到 System32 / SysWOW64 / drivers (' + $copySet.Count + ' 個套件,遞迴,同名同目的取最新版)')
$destSystem32 = Join-Path $vmDrive 'Windows\System32'
$destSysWOW64 = Join-Path $vmDrive 'Windows\SysWOW64'
$destDrivers  = Join-Path $vmDrive 'Windows\System32\drivers'
if (-not (Test-Path $destDrivers)) {
    New-Item -Path $destDrivers -ItemType Directory -Force | Out-Null
}

$flatPrefixes = @()
if ($vp.ContainsKey('FlattenPrefixes')) { $flatPrefixes = @($vp.FlattenPrefixes | ForEach-Object { $_.ToLower() }) }

# 建攤平計畫。$plan: key(檔名|目的地) -> @{ Src; Dest; DestName; Ver; Name }
$plan = @{}
$skipPrefix = 0; $skipUnreadable = 0
foreach ($folder in $copySet) {
    foreach ($f in @(Get-ChildItem $folder.FullName -Recurse -File -ErrorAction SilentlyContinue)) {
        $ext = $f.Extension.ToLower()
        if ($ext -ne '.sys' -and $ext -ne '.dll' -and $ext -ne '.exe') { continue }
        if ($flatPrefixes.Count -gt 0) {
            $nl = $f.Name.ToLower(); $okPre = $false
            foreach ($pre in $flatPrefixes) { if ($nl.StartsWith($pre)) { $okPre = $true; break } }
            if (-not $okPre) { $skipPrefix++; continue }
        }
        $dest = $null; $destName = $null
        if ($ext -eq '.sys') {
            $dest = $destDrivers; $destName = 'drivers'
        } else {
            $arch = Get-ExeArch $f.FullName
            if ($arch -eq 'Error') {
                $skipUnreadable++
                W-Warn ('  讀不到 PE 標頭,跳過不攤平 (仍在 HostDriverStore): ' + $f.Name)
                continue
            }
            if ($arch -eq 'x86') {
                $dest = $destSysWOW64; $destName = 'SysWOW64'
            } else {
                if ($arch -ne 'x64') { W-Warn ('  非 x86/x64 架構 (' + $arch + '),當 x64 放 System32: ' + $f.Name) }
                $dest = $destSystem32; $destName = 'System32'
            }
        }
        $key = $f.Name.ToLower() + '|' + $destName
        $ver = Get-FileVer $f.FullName
        if ($plan.ContainsKey($key)) {
            $prevV = $plan[$key].Ver
            if ($ver -and ((-not $prevV) -or ($ver -gt $prevV))) {
                $plan[$key] = @{ Src = $f.FullName; Dest = $dest; DestName = $destName; Ver = $ver; Name = $f.Name }
            }
        } else {
            $plan[$key] = @{ Src = $f.FullName; Dest = $dest; DestName = $destName; Ver = $ver; Name = $f.Name }
        }
    }
}

# 執行攤平 (依計畫,每個 key 只複製一次勝出的來源)
# $flatCopiedFrom: 檔名(小寫) -> 落地來源;5c 版本比對用 System32/drivers 的 64 位主檔 (SysWOW64 不記)
$flatCopiedFrom = @{}
$flat64 = 0; $flat86 = 0; $flatSys = 0; $flatFail = 0
foreach ($key in $plan.Keys) {
    $e = $plan[$key]
    try {
        Copy-Item -LiteralPath $e.Src -Destination $e.Dest -Force -ErrorAction Stop
        if ($e.DestName -eq 'drivers') { $flatSys++ }
        elseif ($e.DestName -eq 'SysWOW64') { $flat86++ }
        else { $flat64++ }
        if ($e.DestName -ne 'SysWOW64') { $flatCopiedFrom[$e.Name.ToLower()] = $e.Src }
    } catch {
        $flatFail++
        W-Warn ('  攤平失敗: ' + $e.Name + ' (' + $e.DestName + ') - ' + $_.Exception.Message)
    }
}
$prefixNote = if ($flatPrefixes.Count -gt 0) { '  (前綴白名單略過 ' + $skipPrefix + ' 個非 ' + ($flatPrefixes -join '/') + ' 檔)' } else { '' }
W-OK ('攤平複製: ' + $flat64 + ' 個 -> System32, ' + $flat86 + ' 個 -> SysWOW64, ' + $flatSys + ' 個 -> System32\drivers' + $prefixNote)
if ($skipUnreadable -gt 0) {
    W-Warn ('有 ' + $skipUnreadable + ' 個檔讀不到 PE 標頭已跳過 (若含關鍵檔,5c 會報缺檔)')
}
if ($flatFail -gt 0) {
    W-Warn ('攤平複製有 ' + $flatFail + ' 個失敗 (下面 5c 的關鍵檔與版本比對會揭露是否傷到要害)')
}

# ---------------------------------------------------------
#  5b-2 / 5b-3. NVIDIA 專屬:補搬 CUDA runtime + 從 INF 解析補漏
#  AMD 不需要這兩步 —— OpenGL/Vulkan 已由 marker 套件涵蓋 (atioglxx.dll/amdvlk64.dll
#  已在 5b 遞迴攤平搬過),遞迴攤平已足,不必額外解析 INF。
#  以下區塊語意與 v1.1 完全相同,只是包進 NVIDIA 分支;$gpuFolder/$gpuPkg/$nvRepo
#  是相容 v1.1 原變數名而設的別名。
# ---------------------------------------------------------
if ($venId -eq '10DE') {
    $gpuFolder = $chosenDisplay
    $gpuPkg    = $chosenDisplay
    $nvRepo    = $copySet

    W-Step '補搬 CUDA runtime / NVENC / NVFBC (modern OpenGL 相依)'

    # 找一個 DLL 在主機的位置,找不到傳 $null
    # 順序:選中套件 (與搬進 VM 的 KMD/UMD 同版) → 主機 System32 → 其他要搬的套件 → Program Files
    function Find-HostNvDll([string]$name) {
        # 1. 選中的顯示驅動套件 (含子資料夾)
        $hits = Get-ChildItem $gpuFolder.FullName -Filter $name -Recurse -File -ErrorAction SilentlyContinue
        if ($hits) { return $hits[0].FullName }
        # 2. 主機 System32 (現用驅動的即時副本)
        $direct = Join-Path "$env:WinDir\System32" $name
        if (Test-Path $direct) { return $direct }
        # 3. 其他要搬的套件 (已排除非選中的顯示套件)
        foreach ($rf in $nvRepo) {
            if ($rf.FullName -eq $gpuFolder.FullName) { continue }
            $hits = Get-ChildItem $rf.FullName -Filter $name -Recurse -File -ErrorAction SilentlyContinue
            if ($hits) { return $hits[0].FullName }
        }
        # 4. NVIDIA Program Files (NVSMI / NvContainer / 等等)
        foreach ($pf in @('C:\Program Files\NVIDIA Corporation','C:\Program Files (x86)\NVIDIA Corporation')) {
            if (Test-Path $pf) {
                $hits = Get-ChildItem $pf -Filter $name -Recurse -File -ErrorAction SilentlyContinue
                if ($hits) { return $hits[0].FullName }
            }
        }
        return $null
    }

    $essentialDlls = @(
        [PSCustomObject]@{ Name = 'nvcuda.dll';            Critical = $true;  Note = 'CUDA Driver API' }
        [PSCustomObject]@{ Name = 'nvcompiler.dll';        Critical = $true;  Note = 'NVRTC 編譯器' }
        [PSCustomObject]@{ Name = 'nvfatbinaryLoader.dll'; Critical = $true;  Note = 'CUDA fatbin loader' }
        [PSCustomObject]@{ Name = 'nvptxJitCompiler.dll';  Critical = $true;  Note = 'PTX JIT 編譯器' }
        [PSCustomObject]@{ Name = 'nvcudadebugger.dll';    Critical = $false; Note = 'CUDA debugger' }
        [PSCustomObject]@{ Name = 'nvopencl.dll';          Critical = $false; Note = 'OpenCL ICD' }
        [PSCustomObject]@{ Name = 'nvcuvid.dll';           Critical = $false; Note = 'CUDA 影片解碼' }
        [PSCustomObject]@{ Name = 'nvencodeapi64.dll';     Critical = $false; Note = 'NVENC API' }
        [PSCustomObject]@{ Name = 'NvFBC64.dll';           Critical = $false; Note = 'NV Frame Buffer Capture' }
    )

    $essOK = 0; $essCriticalMiss = 0; $essOptionalMiss = 0
    foreach ($e in $essentialDlls) {
        $src = Find-HostNvDll $e.Name
        if (-not $src) {
            if ($e.Critical) {
                W-Err ('  缺 ' + $e.Name + ' (' + $e.Note + ')  <-- 主機完全找不到')
                $essCriticalMiss++
            } else {
                W-Warn ('  缺 ' + $e.Name + ' (' + $e.Note + ',非關鍵)')
                $essOptionalMiss++
            }
            continue
        }

        $copiedAny = $false
        # 主放 VM 的 System32 (Windows DLL 搜尋路徑會找這裡)
        $dst1 = Join-Path $destSystem32 $e.Name
        try {
            Copy-Item -LiteralPath $src -Destination $dst1 -Force -ErrorAction Stop
            $copiedAny = $true
        } catch {
            W-Warn ('    System32 寫入失敗: ' + $_.Exception.Message)
        }

        # 備援:VM HostDriverStore 內選中套件的資料夾也補一份
        $vmGfPath = Join-Path $destDriverRoot $gpuPkg.Name
        if (Test-Path $vmGfPath) {
            $dst2 = Join-Path $vmGfPath $e.Name
            try { Copy-Item -LiteralPath $src -Destination $dst2 -Force -ErrorAction SilentlyContinue } catch {}
        }

        if ($copiedAny) {
            $essOK++
            W-Info ('  [+] ' + $e.Name + '  <- ' + $src)
            $flatCopiedFrom[$e.Name.ToLower()] = $src
        }
    }

    if ($essCriticalMiss -gt 0) {
        W-Err ("[!] 有 $essCriticalMiss 個關鍵 CUDA runtime DLL 主機完全沒有")
        W-Info '建議: 到 NVIDIA 官網下載 Game Ready Driver,選「自訂安裝」,把所有元件都勾起來重裝'
        W-Info '關鍵 CUDA runtime 缺檔 -> VM 內 OpenGL 一定起不來 (nvoglv64 載不起來)'
    } else {
        W-OK ("modern GL 相依 DLL 補搬: 成功 $essOK 個 (非關鍵缺漏 $essOptionalMiss 個)")
    }

    # ---------------------------------------------------------
    #  5b-3. 從 INF 解析 NVIDIA 驅動宣告的所有檔案 → 補漏
    #  仿 Easy-GPU-PV 的 master file list 思路,但動態從 inf 讀 (只讀選中套件的 inf)
    # ---------------------------------------------------------
    W-Step '從 INF 解析驅動檔案清單 → 比對 VM 補漏'

    function Get-NvFilesFromInf([string]$infPath) {
        if (-not (Test-Path $infPath)) { return @() }
        # NVIDIA inf 一般是 UTF-16 LE,Get-Content 要指定 encoding 才不會亂碼
        $content = $null
        foreach ($enc in @('Unicode','UTF8','Default')) {
            try {
                $content = Get-Content -LiteralPath $infPath -Raw -Encoding $enc -ErrorAction Stop
                if ($content -and $content -match '\[Version\]') { break }
            } catch {}
        }
        if (-not $content) { return @() }

        $files = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

        # 主來源:[SourceDisksFiles] 是 inf 規格定義「所有 source 檔案」的 section
        $sdfMatch = [regex]::Match(
            $content,
            '(?ms)^\s*\[SourceDisksFiles[^\]]*\](.+?)(?=^\s*\[|\z)',
            [System.Text.RegularExpressions.RegexOptions]'IgnoreCase, Multiline'
        )
        if ($sdfMatch.Success) {
            # 每行格式:  filename.ext = diskID, subdir, ...
            [regex]::Matches(
                $sdfMatch.Groups[1].Value,
                '(?im)^\s*([\w\-\.]+\.(?:dll|sys|exe|cat|cpl|bin))\s*='
            ) | ForEach-Object { [void]$files.Add($_.Groups[1].Value) }
        }

        # 備援:整 inf 全文 regex 抓 nv* 開頭的提及 (有些 inf 用不同 section 名)
        if ($files.Count -lt 5) {
            [regex]::Matches($content, '(?i)\b(nv[\w\-]+\.(?:dll|sys|exe))\b') |
                ForEach-Object { [void]$files.Add($_.Groups[1].Value) }
        }

        return @($files | Sort-Object)
    }

    # 收集選中套件 inf 內宣告的檔案
    $declaredFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $infs = Get-ChildItem $gpuFolder.FullName -Filter '*.inf' -File -ErrorAction SilentlyContinue
    foreach ($inf in $infs) {
        $list = Get-NvFilesFromInf $inf.FullName
        foreach ($f in $list) { [void]$declaredFiles.Add($f) }
        if ($list.Count -gt 0) {
            W-Info ("  解析 $($inf.Name): 宣告 $($list.Count) 個檔案")
        }
    }

    # 只看 nv* 開頭 (避免動到非 NVIDIA 系統檔像 d3dcompiler / atiicdxx 之類)
    $nvDeclared = @($declaredFiles | Where-Object { $_ -imatch '^nv' } | Sort-Object)
    W-Info ("  總計 nv* 宣告檔案: $($nvDeclared.Count) 個 (扣除其他 vendor / 系統檔)")

    $infOK = 0; $infMiss = 0; $infSkipped = 0; $infIs32 = 0
    foreach ($fname in $nvDeclared) {
        # 跳過 32-bit 變體 (5b 已有遞迴 + PE 架構分流,避免重複處理)
        if ($fname -imatch '(?<![\d])(32)\.(dll|exe)$') { $infIs32++; continue }

        $ext = [System.IO.Path]::GetExtension($fname).ToLower()
        $destFolder = switch ($ext) {
            '.sys' { $destDrivers }
            '.dll' { $destSystem32 }
            '.exe' { $destSystem32 }
            default { $null }
        }
        if (-not $destFolder) { continue }   # .cat / .cpl 之類不主動搬到 System32

        $vmDest = Join-Path $destFolder $fname
        if (Test-Path $vmDest) { $infSkipped++; continue }   # 5a/5b/5b-2 已經放好了

        $src = Find-HostNvDll $fname
        if (-not $src) { $infMiss++; continue }              # 主機真的沒有

        try {
            Copy-Item -LiteralPath $src -Destination $vmDest -Force -ErrorAction Stop
            $infOK++
            $tag = if ($ext -eq '.sys') { 'drivers' } else { 'System32' }
            W-Info ("  [+] $fname -> $tag")
            $flatCopiedFrom[$fname.ToLower()] = $src
        } catch {
            W-Warn ("  [!] $fname : $($_.Exception.Message)")
        }
    }

    W-OK ("INF 補漏完成:新搬 $infOK 個 / VM 已有 $infSkipped 個 / 主機無 $infMiss 個 / 32-bit 略過 $infIs32 個")
}

# ---------------------------------------------------------
#  5c. 自我檢查 - 關鍵檔案是否到位 + 版本是否等於來源套件 (v2:依 $vp.CheckFiles /
#  $vp.VerCheckFiles 廠牌化,取代 v1.1 寫死的 NVIDIA 檔名清單)
# ---------------------------------------------------------
W-Step ('自我檢查 ' + $vendorName + ' 關鍵檔案')
$missingCritical = 0
foreach ($chk in $vp.CheckFiles) {
    $p = Join-Path $vmDrive $chk.Rel
    if (Test-Path $p) {
        $sz = (Get-Item $p).Length
        W-OK ('  OK   ' + $chk.Name + '  (' + ('{0:N0}' -f $sz) + ' bytes)')
    } else {
        if ($chk.Critical) {
            W-Err ('  缺   ' + $chk.Name)
            $missingCritical++
        } else {
            W-Warn ('  缺   ' + $chk.Name + ' (非關鍵)')
        }
    }
}

# 版本比對:VM 內檔案版本必須等於「實際複製來源」的版本 (來源取自 5b 攤平時記錄的
# $flatCopiedFrom,同名檔可能存在於多個套件,以真正落地 VM 的那份為準,不是隨便挑一個)
W-Step ('版本比對 (主顯示套件 ' + $chosenDisplay.Name + ',版本 ' + $chosenDisplay.DisplayVer + ')')
$verMismatch = 0
foreach ($vc in $vp.VerCheckFiles) {
    $vmPath = Join-Path $vmDrive $vc.VmRel
    $srcPath = $flatCopiedFrom[$vc.SrcKey.ToLower()]
    if (-not $srcPath) {
        W-Warn ('  找不到 ' + $vc.SrcKey + ' 的複製來源紀錄,跳過比對')
        continue
    }
    $srcV = Get-FileVer $srcPath
    $vmV  = Get-FileVer $vmPath
    if (-not $srcV) {
        W-Warn ('  來源檔案沒有版本資訊: ' + $vc.Name + ',跳過比對')
        continue
    }
    if (-not $vmV) {
        W-Err ('  VM 缺 ' + $vc.Name + ' (來源 ' + $srcV + ')')
        $verMismatch++
    } elseif ($vmV -ne $srcV) {
        W-Err ('  版本不符 ' + $vc.Name + ': VM=' + $vmV + '  來源=' + $srcV)
        $verMismatch++
    } else {
        W-OK ('  版本一致 ' + $vc.Name + ' = ' + $vmV)
    }
}

# NVIDIA 專屬額外檢查 (v1.1 原有,v2 僅 NVIDIA 保留;AMD 未要求此項):
# HostDriverStore 那份不是備份,GPU-PV 的 VM 就是從這個資料夾載 UMD,版本不對遊戲一定壞
if ($venId -eq '10DE') {
    $vmPkgDir = Join-Path $destDriverRoot $chosenDisplay.Name
    $hdsSrcPath = Join-Path $gpuFolder.FullName 'nvlddmkm.sys'
    $hdsVmPath  = Join-Path $vmPkgDir 'nvlddmkm.sys'
    $hdsName = 'HostDriverStore\<套件>\nvlddmkm.sys (VM 實際載入位置)'
    $srcV = Get-FileVer $hdsSrcPath
    $vmV  = Get-FileVer $hdsVmPath
    if (-not $srcV) {
        W-Warn ('  來源套件沒有 ' + $hdsName + ',跳過比對')
    } elseif (-not $vmV) {
        W-Err ('  VM 缺 ' + $hdsName + ' (來源 ' + $srcV + ')')
        $verMismatch++
    } elseif ($vmV -ne $srcV) {
        W-Err ('  版本不符 ' + $hdsName + ': VM=' + $vmV + '  來源=' + $srcV)
        $verMismatch++
    } else {
        W-OK ('  版本一致 ' + $hdsName + ' = ' + $vmV)
    }
}

if ($missingCritical -gt 0 -or $verMismatch -gt 0 -or $hdsFail -gt 0) {
    W-Warn ('有 ' + $missingCritical + ' 個關鍵檔案缺失、' + $verMismatch + ' 個版本不符/缺檔、' + $hdsFail + ' 個 HostDriverStore 套件沒複製成功,VM 開機後可能仍無法建立 D3D12 / OpenGL')
    W-Info ('請檢查主機 ' + $vendorName + ' 驅動是否完整,或關掉佔用 VHDX 的程式後重跑')
} else {
    W-OK '所有關鍵檔案已到位,版本與來源套件一致'
}

# (DriverOnly 版:此處刻意沒有 5d 遊戲複製區塊)

# =========================================================
#  6. 卸載 VHDX
# =========================================================
W-Step '卸載 VHDX'
try {
    Dismount-VHD -Path $vhdPath -ErrorAction Stop
    W-OK '卸載完成'
} catch {
    W-Err ('卸載失敗(可能被佔用): ' + $_.Exception.Message)
    W-Info '請手動關閉所有開啟的檔案總管視窗後再跑一次 Dismount-VHD'
}

# =========================================================
#  7. 結尾
# =========================================================
W-Title ('完成 - GPU-PV 直通配置 DriverOnly v2 (' + $vendorName + ',未搬任何遊戲)')

Write-Host ''
Write-Host '目前 VM 狀態:' -ForegroundColor White
$vmNow = Get-VM -Name $vmName
$gpuNow = @(Get-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue).Count
W-Info ('名稱           : ' + $vmNow.Name)
W-Info ('狀態           : ' + $vmNow.State)
W-Info ('GPU 分區介面卡 : ' + $gpuNow + ' 個 (應為 1)')
W-Info ('動態記憶體     : ' + (Get-VMMemory -VMName $vmName).DynamicMemoryEnabled)
W-Info ('顯卡廠牌       : ' + $vendorName + ' (VEN_' + $venId + ')')
W-Info ('搬入驅動套件   : ' + $chosenDisplay.Name + '  [' + $chosenDisplay.DisplayVer + ']')
W-Info ('清除舊驅動檔   : ' + $(if ($doClean) { '有 (-CleanOld,乾淨重裝)' } else { '無 (只覆蓋同名檔)' }))
W-Info ('HostDriverStore : 成功 ' + $hdsOK + ' 個 / 失敗 ' + $hdsFail + ' 個套件;攤平失敗 ' + $flatFail + ' 檔')

Write-Host ''
Write-Host '下一步:' -ForegroundColor Yellow
Write-Host '  1. 啟動 VM,等 2-3 分鐘讓 Windows 完成驅動辨識'
if ($venId -eq '10DE') {
    Write-Host '  2. VM 裡開裝置管理員,顯示卡應為「一張」NVIDIA GeForce RTX (不再是兩張同名卡,'
    Write-Host '     也不是 Microsoft Basic Render)'
    Write-Host '  3. VM 內以系統管理員跑 D3D12 smoke test (或 dxdiag 顯示卡分頁),'
    Write-Host '     確認對 NVIDIA 卡能建立 D3D12 裝置 (FL11_0 OK),再開遊戲'
    Write-Host '  4. 若 OpenGL 仍跳錯 (no driver / Microsoft Basic Render Driver),'
    Write-Host '     在 VM 內跑 VM_NVFix_v1.0.bat 修補登錄檔'
    Write-Host '  5. 在 VM 跑這個確認驅動有搬到位:'
    Write-Host '       Test-Path C:\Windows\System32\nvoglv64.dll'
    Write-Host '     回 True 才代表這次有搬到位'
} else {
    Write-Host '  2. VM 裡開裝置管理員,顯示卡應為「一張」AMD Radeon (不再是兩張同名卡,'
    Write-Host '     也不是 Microsoft Basic Render)'
    Write-Host '  3. VM 內以系統管理員跑 D3D12 smoke test (或 dxdiag 顯示卡分頁),'
    Write-Host '     確認對 AMD 卡能建立 D3D12 裝置 (FL11_0 OK),再開遊戲'
    Write-Host '  4. 在 VM 跑這個確認驅動有搬到位:'
    Write-Host '       Test-Path C:\Windows\System32\drivers\amdkmdag.sys'
    Write-Host '     回 True 才代表這次有搬到位'
}
Write-Host '  (本版不搬遊戲;要搬遊戲請跑 Host_Master_v1.7 或 Game_Share_GUI)'
Write-Host ''

if (Ask-YN '要立即啟動 VM 嗎?') {
    try {
        Start-VM -Name $vmName -ErrorAction Stop
        W-OK ('已啟動 ' + $vmName)
    } catch {
        W-Err ('啟動失敗: ' + $_.Exception.Message)
    }
}

Write-Host ''
if ($gpuNow -eq 1 -and $missingCritical -eq 0 -and $verMismatch -eq 0 -and $hdsFail -eq 0 -and $flatFail -eq 0) { exit 0 } else { exit 1 }
