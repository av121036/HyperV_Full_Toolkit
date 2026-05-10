# =========================================================
#  Host_Master_v1.5.ps1  -  Hyper-V GPU-PV 直通 + 顯卡驅動複製
#  v1.6 - 補搬 modern OpenGL / CUDA runtime 相依 DLL (新增 5b-2 + 5b-3)
#         R535+ 之後 NVIDIA 的 nvoglv64.dll 在初始化時會 LoadLibrary:
#           nvcuda.dll / nvcompiler.dll /
#           nvfatbinaryLoader.dll / nvptxJitCompiler.dll
#         任一個缺 -> wglCreateContext 失敗 -> "cannot opengl" / GLFW #65542
#         原 5b 只看 nvoglv64 同層、不遞迴,所以這層漏網。
#
#         5b-2: 指定名字精準補搬 9 個關鍵 DLL
#           - 多位置遞迴搜尋 (System32 / DriverStore / NVIDIA Program Files)
#           - 推到 VM 的 System32 + HostDriverStore 子資料夾
#
#         5b-3: 仿 Easy-GPU-PV 思路,從 inf 解析「驅動宣告的所有檔案」自動補
#           - 讀 [SourceDisksFiles] section 拿完整檔案清單
#           - 動態,不用維護寫死清單,driver 改版自動跟上
#           - 跳過 *32.dll (5b 自有 32-bit 處理邏輯,避免重複)
#           - .dll → System32, .sys → System32\drivers
#
#         自我檢查清單也加入 4 個關鍵 CUDA runtime DLL。
#  v1.5 - 5d 改為「自動偵測」(支援 NC 新版 + NCSOFT 舊版兩種根目錄):
#         1. 掃 Program Files (x86) 下名字是 NC / NCSOFT 的根目錄
#         2. 用關鍵字比對找子資料夾
#            (Lineage / Purple / 天堂 / Aion / Blade / Throne / BnS)
#            新遊戲只要在 $gamePatterns 加一行就好,不用改主邏輯
#         3. 自動估算總大小,VHDX 剩餘空間不足會警告 (但仍嘗試)
#         4. 複製清單會在開始前列出,看到不對按 Ctrl+C 可取消
#  v1.4 - 新增: 自動複製 NCSOFT\Lineage Classic 與 Purple 到 VM
#         (放在 5d 區塊,使用 robocopy 多執行緒搬運)
#  v1.3 - 修正 OpenGL 不能用的問題
#         1. 改用 nvoglv64.dll 存在與否判定真正的 GPU 驅動資料夾
#            (不再亂搬 nvhda / nvvad / nvraid 等不相關項目)
#         2. 把 GPU 驅動資料夾內所有 dll/exe/sys 攤平複製到
#            VM 的 System32 與 System32\drivers
#            (這是 OpenGL ICD nvoglv64.dll 能被載入的關鍵)
#         3. 跑完自我檢查 nvoglv64.dll / nvlddmkm.sys 是否就位
# =========================================================

$ErrorActionPreference = 'Stop'
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

W-Title 'GPU-PV 直通 + 驅動複製工具 v1.6'

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

# v1.3: 改用「裡面有 nvoglv64.dll」判定哪個資料夾才是真正的 GPU 驅動
# (新版 NVIDIA 用 nvmdsi.inf 命名,舊版用 nvami.inf / nvlddmkm.inf,
#  不能再用 nv* 暴力 filter 否則 nvhda nvvad 全進來)
W-Step '搜尋 GPU 驅動資料夾 (含 nvoglv64.dll)'
$repoRoot = "$env:WinDir\System32\DriverStore\FileRepository"
$gpuFolders = @()
$candidates = Get-ChildItem $repoRoot -Filter 'nv*.inf_amd64_*' -Directory -ErrorAction SilentlyContinue
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c.FullName 'nvoglv64.dll')) {
        $gpuFolders += $c
    }
}
if ($gpuFolders.Count -eq 0) {
    W-Err '在 DriverStore 找不到包含 nvoglv64.dll 的資料夾'
    W-Info '請先在主機安裝 NVIDIA 正式驅動 (GeForce / Studio Driver) 再跑本工具'
    W-Info '注意: 只裝 nForce 晶片組或音效驅動是不夠的'
    exit 1
}
W-OK ('找到 GPU 驅動資料夾: ' + $gpuFolders.Count + ' 個')
foreach ($f in $gpuFolders) {
    $kmd = Join-Path $f.FullName 'nvlddmkm.sys'
    $kmdTag = if (Test-Path $kmd) { ' [含 KMD]' } else { ' [缺 KMD!]' }
    W-Info ('  ' + $f.Name + $kmdTag)
}

# 同時保留原本邏輯的所有 nv* 資料夾 (給 HostDriverStore 整包複製用)
$nvRepo = $candidates
W-Info ('DriverStore 內所有 nv* 資料夾: ' + $nvRepo.Count + ' 個 (整包搬到 VM HostDriverStore)')

# 檢查主機顯卡
try {
    $hostGpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX' } | Select-Object -First 1
    if ($hostGpu) {
        W-OK ('主機顯卡: ' + $hostGpu.Name + '  驅動版本: ' + $hostGpu.DriverVersion)
    }
} catch {}

# =========================================================
#  1. 選擇目標 VM
# =========================================================
W-Step '選擇目標 VM'
$vms = @(Get-VM | Where-Object { $_.Generation -eq 2 } | Sort-Object Name)
if ($vms.Count -eq 0) {
    W-Err '找不到 Generation 2 VM。GPU-PV 需要 Gen 2 VM。'
    exit 1
}

Write-Host ''
Write-Host 'Gen 2 VM 清單:' -ForegroundColor White
for ($i = 0; $i -lt $vms.Count; $i++) {
    $v = $vms[$i]
    $color = if ($v.State -eq 'Running') { 'Green' } else { 'Gray' }
    Write-Host ('  [{0}] {1,-30} ({2})' -f ($i + 1), $v.Name, $v.State) -ForegroundColor $color
}
Write-Host ''
$raw = Read-Host '請輸入 VM 編號'
if (-not ($raw -as [int]) -or [int]$raw -lt 1 -or [int]$raw -gt $vms.Count) {
    W-Err '無效的編號'
    exit 1
}
$vm = $vms[[int]$raw - 1]
$vmName = $vm.Name
W-OK ('已選擇: ' + $vmName)

# =========================================================
#  2. 確認 VM 已關機 (GPU-PV 設定與掛載 VHDX 都需要)
# =========================================================
if ($vm.State -ne 'Off') {
    Write-Host ''
    W-Warn ('VM 目前狀態: ' + $vm.State + '  本操作需要 VM 關機。')
    $yn = Read-Host '要立即關機嗎?(Y/N)'
    if ($yn -match '^[Yy]') {
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
    $yn = Read-Host '要刪除所有檢查點嗎?(Y/N)'
    if ($yn -match '^[Yy]') {
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
    Write-Host ('[!] VM 只有 ' + $currentCores + ' 核,天堂可能卡頓。建議 4 核起跳。') -ForegroundColor Yellow
    $yn = Read-Host '要立即調整為 4 核嗎?(Y/N)'
    if ($yn -match '^[Yy]') {
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

W-Step '設定 GPU-PV 必要參數 (MMIO + Cache)'
try {
    Set-VM -Name $vmName -GuestControlledCacheTypes $true
    Set-VM -Name $vmName -LowMemoryMappedIoSpace 3Gb
    Set-VM -Name $vmName -HighMemoryMappedIoSpace 32Gb
    W-OK 'GuestControlledCacheTypes=True, LowMMIO=3GB, HighMMIO=32GB'
} catch { W-Err ('失敗: ' + $_.Exception.Message) }

$vmMem = Get-VMMemory -VMName $vmName
W-Info ('VM 記憶體: {0:N0} MB (Startup), 動態記憶體: {1}' -f `
    ($vmMem.Startup / 1MB), $vmMem.DynamicMemoryEnabled)
if (($vmMem.Startup / 1GB) -lt 4) {
    W-Warn '建議 VM 記憶體至少 4GB 以上,GPU-PV 才穩定'
}

# =========================================================
#  4. 加入 GPU 分區介面卡
# =========================================================
W-Step '重新加入 GPU 分區介面卡'
try {
    $existing = @(Get-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        W-Info ('移除既有 ' + $existing.Count + ' 個 GPU 分區')
        $existing | ForEach-Object { Remove-VMGpuPartitionAdapter -VMName $vmName -AdapterId $_.Id }
    }
    Add-VMGpuPartitionAdapter -VMName $vmName -ErrorAction Stop
    W-OK 'GPU 分區介面卡已加入'

    $gpuAdapter = Get-VMGpuPartitionAdapter -VMName $vmName | Select-Object -First 1
    if ($gpuAdapter) {
        Set-VMGpuPartitionAdapter -VMName $vmName `
            -MinPartitionVRAM 80000000 -MaxPartitionVRAM 100000000 -OptimalPartitionVRAM 100000000 `
            -MinPartitionEncode 80000000 -MaxPartitionEncode 100000000 -OptimalPartitionEncode 100000000 `
            -MinPartitionDecode 80000000 -MaxPartitionDecode 100000000 -OptimalPartitionDecode 100000000 `
            -MinPartitionCompute 80000000 -MaxPartitionCompute 100000000 -OptimalPartitionCompute 100000000 `
            -ErrorAction SilentlyContinue
        W-OK 'GPU 分區配額已設定'
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
#  5a. HostDriverStore 整包複製 (保留原 v1.2 行為)
# ---------------------------------------------------------
try {
    $destDriverRoot = Join-Path $vmDrive 'Windows\System32\HostDriverStore\FileRepository'
    if (-not (Test-Path $destDriverRoot)) {
        New-Item -Path $destDriverRoot -ItemType Directory -Force | Out-Null
    }

    foreach ($folder in $nvRepo) {
        $destFolder = Join-Path $destDriverRoot $folder.Name
        W-Step ('複製 DriverStore: ' + $folder.Name)
        if (Test-Path $destFolder) {
            Remove-Item $destFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        Copy-Item -Path $folder.FullName -Destination $destFolder -Recurse -Force -ErrorAction Stop
    }
    W-OK ('HostDriverStore 已複製 ' + $nvRepo.Count + ' 個資料夾')
} catch {
    W-Err ('HostDriverStore 複製失敗: ' + $_.Exception.Message)
}

# ---------------------------------------------------------
#  5b. v1.3 新增: 從 GPU 驅動資料夾「攤平」複製到 System32
# ---------------------------------------------------------
W-Step 'v1.3: 從 GPU 驅動資料夾攤平到 System32 / drivers'
$destSystem32 = Join-Path $vmDrive 'Windows\System32'
$destSysWOW64 = Join-Path $vmDrive 'Windows\SysWOW64'
$destDrivers  = Join-Path $vmDrive 'Windows\System32\drivers'

if (-not (Test-Path $destDrivers)) {
    New-Item -Path $destDrivers -ItemType Directory -Force | Out-Null
}

$flatDll = 0; $flatExe = 0; $flatSys = 0; $flat32 = 0
foreach ($gpuFolder in $gpuFolders) {
    W-Info ('來源: ' + $gpuFolder.Name)

    # .sys -> drivers
    Get-ChildItem $gpuFolder.FullName -Filter '*.sys' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Copy-Item $_.FullName -Destination $destDrivers -Force -ErrorAction Stop
            $flatSys++
        } catch {}
    }

    # .dll -> System32 (64-bit)
    Get-ChildItem $gpuFolder.FullName -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Copy-Item $_.FullName -Destination $destSystem32 -Force -ErrorAction Stop
            $flatDll++
        } catch {}
    }

    # .exe -> System32
    Get-ChildItem $gpuFolder.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Copy-Item $_.FullName -Destination $destSystem32 -Force -ErrorAction Stop
            $flatExe++
        } catch {}
    }

    # 32-bit subfolder (NVIDIA 把 32-bit 放在子資料夾,通常叫 'x86' 或 'wow' 或 dll 命名 nvogl*32 在根目錄)
    # 先掃同資料夾根目錄底下名字含 "32" 的 dll -> SysWOW64
    Get-ChildItem $gpuFolder.FullName -Filter '*32.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Copy-Item $_.FullName -Destination $destSysWOW64 -Force -ErrorAction Stop
            $flat32++
        } catch {}
    }

    # 也掃子資料夾找 32-bit (有些版本放在 'x86_32' 之類)
    $sub32 = Get-ChildItem $gpuFolder.FullName -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -match '32|x86|wow' }
    foreach ($s in $sub32) {
        Get-ChildItem $s.FullName -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Copy-Item $_.FullName -Destination $destSysWOW64 -Force -ErrorAction Stop
                $flat32++
            } catch {}
        }
    }
}
W-OK ('攤平複製: ' + $flatDll + ' 個 DLL -> System32, ' + `
       $flatExe + ' 個 EXE -> System32, ' + `
       $flatSys + ' 個 SYS -> System32\drivers, ' + `
       $flat32 + ' 個 32-bit DLL -> SysWOW64')

# ---------------------------------------------------------
#  5b-2. v1.6 新增: 補搬 modern OpenGL / CUDA runtime 必要 DLL
#  R535+ 之後的 NVIDIA OpenGL ICD (nvoglv64.dll) 初始化時會 LoadLibrary:
#    nvcuda.dll / nvcompiler.dll / nvfatbinaryLoader.dll / nvptxJitCompiler.dll
#  任一個缺 -> wglCreateContext 失敗 -> GPU Caps Viewer 秒退,
#  L1C / Minecraft 等 OpenGL 遊戲跳 "cannot opengl"
#
#  這些檔案常見位置:
#    1. C:\Windows\System32\                                       (主機已部署版本)
#    2. DriverStore\FileRepository\nv*.inf_amd64_*\<深層子資料夾>\ (Driver 包內)
#    3. C:\Program Files\NVIDIA Corporation\<某些子資料夾>\
#  原 5b 只看 gpuFolder 根目錄不遞迴,所以這層漏網。
#  這裡用「指定名字 + 多位置遞迴搜尋」精準補搬,確保 VM 的 System32 都有。
# ---------------------------------------------------------
W-Step 'v1.6: 補搬 CUDA runtime / NVENC / NVFBC (modern OpenGL 相依)'

# 多位置遞迴搜尋一個 DLL 在主機的位置,找不到傳 $null
function Find-HostNvDll([string]$name) {
    # 1. System32 直接命中 (最快)
    $direct = Join-Path "$env:WinDir\System32" $name
    if (Test-Path $direct) { return $direct }
    # 2. DriverStore 全域遞迴 (含 nv*.inf_amd64_* 內所有子資料夾)
    $hits = Get-ChildItem "$env:WinDir\System32\DriverStore\FileRepository" -Filter $name -Recurse -File -ErrorAction SilentlyContinue
    if ($hits) { return $hits[0].FullName }
    # 3. NVIDIA Program Files (NVSMI / NvContainer / 等等)
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

    # 備援:每個 gpuFolder 對應的 VM HostDriverStore 子資料夾也補一份
    # (有些遊戲/反作弊會從 nvoglv64.dll 同層去 LoadLibrary,雙保險)
    foreach ($gf in $gpuFolders) {
        $vmGfPath = Join-Path $destDriverRoot $gf.Name
        if (Test-Path $vmGfPath) {
            $dst2 = Join-Path $vmGfPath $e.Name
            try { Copy-Item -LiteralPath $src -Destination $dst2 -Force -ErrorAction SilentlyContinue } catch {}
        }
    }

    if ($copiedAny) {
        $essOK++
        W-Info ('  [+] ' + $e.Name + '  <- ' + $src)
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
#  5b-3. v1.6 NEW: 從 INF 解析 NVIDIA 驅動宣告的所有檔案 → 補漏
#  仿 Easy-GPU-PV 的 master file list 思路,但動態從 inf 讀,
#  不用維護寫死的 200 個檔名清單。
#
#  邏輯:
#    1. 對每個 gpuFolder 內的 .inf 檔做解析
#    2. 從 [SourceDisksFiles] section 抽出所有 nv*.dll/.sys/.exe
#       (若 section 解不到,退回 regex 全文找 nv* 提及)
#    3. 對每個檔名,如果 VM 對應位置已有 (5a/5b/5b-2 搬過) → skip
#       沒有 → Find-HostNvDll 找,找到就補搬到對的位置
#       (.dll → System32, .sys → System32\drivers, *32.dll → 略過,
#        因為 5b 自有 32-bit 處理邏輯)
#
#  好處:driver 改版加新 DLL 自動跟上,不用改 Host_Master 程式碼。
# ---------------------------------------------------------
W-Step 'v1.6: 從 INF 解析驅動檔案清單 → 比對 VM 補漏'

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

# 收集所有 GPU 驅動 inf 內宣告的檔案 (整合多個顯示驅動 inf)
$declaredFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($gf in $gpuFolders) {
    $infs = Get-ChildItem $gf.FullName -Filter '*.inf' -File -ErrorAction SilentlyContinue
    foreach ($inf in $infs) {
        $list = Get-NvFilesFromInf $inf.FullName
        foreach ($f in $list) { [void]$declaredFiles.Add($f) }
        if ($list.Count -gt 0) {
            W-Info ("  解析 $($inf.Name): 宣告 $($list.Count) 個檔案")
        }
    }
}

# 只看 nv* 開頭 (避免動到非 NVIDIA 系統檔像 d3dcompiler / atiicdxx 之類)
$nvDeclared = @($declaredFiles | Where-Object { $_ -imatch '^nv' } | Sort-Object)
W-Info ("  總計 nv* 宣告檔案: $($nvDeclared.Count) 個 (扣除其他 vendor / 系統檔)")

$infOK = 0; $infMiss = 0; $infSkipped = 0; $infIs32 = 0
foreach ($fname in $nvDeclared) {
    # 跳過 32-bit 變體 (5b 已有 32-bit 子資料夾掃描邏輯,避免重複處理)
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
    } catch {
        W-Warn ("  [!] $fname : $($_.Exception.Message)")
    }
}

W-OK ("INF 補漏完成:新搬 $infOK 個 / VM 已有 $infSkipped 個 / 主機無 $infMiss 個 / 32-bit 略過 $infIs32 個")

# ---------------------------------------------------------
#  5c. 自我檢查 - 關鍵檔案是否到位
# ---------------------------------------------------------
W-Step 'v1.3: 自我檢查 OpenGL / KMD 關鍵檔案'
$checks = @(
    @{ Name = 'nvoglv64.dll (OpenGL ICD 64-bit)';   Path = (Join-Path $destSystem32 'nvoglv64.dll');           Critical = $true  }
    @{ Name = 'nvoglv32.dll (OpenGL ICD 32-bit)';   Path = (Join-Path $destSysWOW64 'nvoglv32.dll');           Critical = $false }
    @{ Name = 'nvlddmkm.sys (Kernel Mode Driver)';  Path = (Join-Path $destDrivers  'nvlddmkm.sys');           Critical = $true  }
    @{ Name = 'nvldumdx.dll (User Mode Driver)';    Path = (Join-Path $destSystem32 'nvldumdx.dll');           Critical = $true  }
    @{ Name = 'nvapi64.dll (NVAPI)';                Path = (Join-Path $destSystem32 'nvapi64.dll');            Critical = $false }
    # v1.6: modern OpenGL ICD 相依
    @{ Name = 'nvcuda.dll (CUDA Driver API)';       Path = (Join-Path $destSystem32 'nvcuda.dll');             Critical = $true  }
    @{ Name = 'nvcompiler.dll (NVRTC)';             Path = (Join-Path $destSystem32 'nvcompiler.dll');         Critical = $true  }
    @{ Name = 'nvfatbinaryLoader.dll';              Path = (Join-Path $destSystem32 'nvfatbinaryLoader.dll');  Critical = $true  }
    @{ Name = 'nvptxJitCompiler.dll';               Path = (Join-Path $destSystem32 'nvptxJitCompiler.dll');   Critical = $true  }
)
$missingCritical = 0
foreach ($chk in $checks) {
    if (Test-Path $chk.Path) {
        $sz = (Get-Item $chk.Path).Length
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

if ($missingCritical -gt 0) {
    W-Warn ('有 ' + $missingCritical + ' 個關鍵檔案缺失,VM 開機後可能仍無法用 OpenGL')
    W-Info '請檢查主機 NVIDIA 驅動是否完整 (跑 GeForce Experience 或 NVIDIA App 重新安裝)'
} else {
    W-OK '所有關鍵檔案已到位'
}

# ---------------------------------------------------------
#  5d. v1.5: 自動偵測並複製 NCSOFT 系列遊戲資料夾
#       邏輯:
#       1. 掃 Program Files (x86) 底下名字是 NC / NCSOFT 的根目錄
#       2. 進去找子資料夾名稱含關鍵字的全部搬
#          (Lineage / Purple / 天堂 / Aion / Blade / Throne / BnS)
#       3. 想加新遊戲 -> 編輯 $gamePatterns
#          想加新位置 -> 編輯 $extraSearchRoots
# ---------------------------------------------------------
W-Title 'v1.5: 自動偵測並複製 NCSOFT 遊戲資料夾'

# === 可調參數 (改這裡就能擴充支援) ===
$ncRootKeys = @('NC', 'NCSOFT')
$gamePatterns = @(
    'Lineage',     # Lineage / Lineage Classic / Lineage 2 / Lineage W
    'Purple',      # NCSOFT 啟動器
    '天堂',        # 中文版 Lineage 系列 (天堂Classic / 天堂W ...)
    'Aion',        # 永恆紀元
    'Blade',       # Blade & Soul / 劍靈
    'Throne',      # Throne and Liberty (TL)
    'BnS'          # B&S 縮寫資料夾
)
# 如果遊戲裝在不同碟 (例如 D:\Games),在這加路徑
$extraSearchRoots = @()
# === 可調參數結束 ===

$searchRoots = @()
$pfx86 = ${env:ProgramFiles(x86)}
if (-not $pfx86) { $pfx86 = 'C:\Program Files (x86)' }
if (Test-Path $pfx86) { $searchRoots += $pfx86 }
foreach ($extra in $extraSearchRoots) {
    if (Test-Path $extra) { $searchRoots += $extra }
}

W-Step '掃描可能的遊戲根目錄'
foreach ($root in $searchRoots) { W-Info ('  掃描: ' + $root) }

$copyJobs = @()
foreach ($root in $searchRoots) {
    Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object {
        $name = $_.Name
        $hit = $false
        foreach ($k in $ncRootKeys) { if ($name -ieq $k) { $hit = $true; break } }
        $hit
    } | ForEach-Object {
        $ncRoot = $_
        W-Info ('  發現根目錄: ' + $ncRoot.FullName)

        Get-ChildItem $ncRoot.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $gameName = $_.Name
            $matched = $false
            foreach ($pat in $gamePatterns) {
                if ($gameName -match $pat) { $matched = $true; break }
            }
            if (-not $matched) { return }

            # 用相對於 Program Files (x86) 的路徑保留原本資料夾結構
            $rel = $_.FullName.Substring($root.Length).TrimStart('\','/')
            $copyJobs += [PSCustomObject]@{
                RootName = $ncRoot.Name
                GameName = $gameName
                Src      = $_.FullName
                Dst      = Join-Path $vmDrive ('Program Files (x86)\' + $rel)
            }
        }
    }
}

if ($copyJobs.Count -eq 0) {
    W-Warn '沒有偵測到任何符合的遊戲資料夾,跳過此步驟'
    W-Info '如果你的遊戲裝在別的位置 (例如 D:\Games\NCSOFT),請編輯本檔案'
    W-Info '搜尋 "v1.5: 自動偵測" 區塊,把路徑加進 $extraSearchRoots'
    W-Info '若是新遊戲,把資料夾名稱關鍵字加進 $gamePatterns'
} else {
    W-OK ('偵測到 ' + $copyJobs.Count + ' 個遊戲資料夾要複製')
    Write-Host ''
    Write-Host '  複製清單 (按 Ctrl+C 可取消):' -ForegroundColor White
    foreach ($j in $copyJobs) {
        Write-Host ('    [' + $j.RootName + '] ' + $j.GameName) -ForegroundColor Gray
        Write-Host ('       來源: ' + $j.Src) -ForegroundColor DarkGray
        Write-Host ('       目的: ' + $j.Dst) -ForegroundColor DarkGray
    }
    Write-Host ''

    # 估算總大小 + 比對 VHDX 剩餘空間
    W-Step '估算總大小並檢查 VHDX 剩餘空間'
    $totalSrcBytes = 0
    foreach ($j in $copyJobs) {
        try {
            $sz = (Get-ChildItem $j.Src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($sz) { $totalSrcBytes += $sz }
        } catch {}
    }
    W-Info ('  總計需要: {0:N2} GB' -f ($totalSrcBytes / 1GB))

    $vol = $null
    try {
        $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        if ($vol) {
            W-Info ('  VM 系統碟 ' + $vmDrive + ' 剩餘: {0:N2} GB / 容量 {1:N2} GB' -f `
                ($vol.SizeRemaining / 1GB), ($vol.Size / 1GB))
            if ($vol.SizeRemaining -lt ($totalSrcBytes * 1.05)) {
                W-Warn '  VHDX 剩餘空間不足建議值 (來源 +5%),建議先擴充 VHDX'
                W-Warn '  會繼續嘗試,中途失敗請手動擴充 VHDX 後重跑'
            }
        }
    } catch {}

    Write-Host ''

    # 一個一個用 robocopy 搬
    $jobIdx = 0
    foreach ($j in $copyJobs) {
        $jobIdx++

        # 為每個遊戲建立目的根目錄 (NC\ 或 NCSOFT\)
        $dstParent = Split-Path $j.Dst -Parent
        if (-not (Test-Path $dstParent)) {
            try {
                New-Item -Path $dstParent -ItemType Directory -Force | Out-Null
            } catch {
                W-Err ('  建立目的資料夾失敗: ' + $_.Exception.Message)
                continue
            }
        }

        $srcSizeGB = 0
        try {
            $srcSizeGB = [math]::Round(((Get-ChildItem $j.Src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB), 2)
        } catch {}

        W-Step ('[' + $jobIdx + '/' + $copyJobs.Count + '] ' + $j.RootName + '\' + $j.GameName + '  (約 ' + $srcSizeGB + ' GB)')
        W-Info ('  目的: ' + $j.Dst)
        W-Info '  robocopy 16 執行緒搬運中,請耐心等候...'

        # /E   含子資料夾 (包含空的)
        # /R:1 /W:2  失敗只重試 1 次,等 2 秒
        # /MT:16    16 條執行緒
        # /XJ       不跟 junction (避免無限遞迴)
        # /NFL /NDL 不列每個檔案/資料夾名稱
        # /NJH /NJS 不印 header / summary
        # /NC /NS   不印 class / size
        # /NP       不印 % progress
        $logSuffix = (($j.RootName + '_' + $j.GameName) -replace '[\s\\\/:*?"<>|]', '_')
        $rcLog = Join-Path $env:TEMP ('robocopy_' + $logSuffix + '.log')
        $rcArgs = @($j.Src, $j.Dst, '/E', '/R:1', '/W:2', '/MT:16', '/XJ',
                    '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP',
                    ('/LOG:' + $rcLog))

        $rcExit = 16
        try {
            & robocopy @rcArgs | Out-Null
            $rcExit = $LASTEXITCODE
        } catch {
            W-Err ('  robocopy 執行失敗: ' + $_.Exception.Message)
            continue
        }

        # robocopy exit code: 0~7 都算正常,>=8 才是錯誤
        if ($rcExit -lt 8) {
            $tag = switch ($rcExit) {
                0 { '無變更' }
                1 { '複製成功' }
                2 { '目的有多餘檔(已忽略)' }
                3 { '複製成功+目的有多餘檔' }
                default { ('code=' + $rcExit) }
            }
            W-OK ('  ' + $j.GameName + ' 完成 (' + $tag + ')')
        } else {
            W-Err ('  ' + $j.GameName + ' 複製失敗 (robocopy code=' + $rcExit + '),log: ' + $rcLog)
        }
    }
}

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
W-Title '完成 - GPU-PV 直通配置 v1.5'

Write-Host ''
Write-Host '目前 VM 狀態:' -ForegroundColor White
$vmNow = Get-VM -Name $vmName
W-Info ('名稱           : ' + $vmNow.Name)
W-Info ('狀態           : ' + $vmNow.State)
W-Info ('GPU 分區介面卡 : ' + (@(Get-VMGpuPartitionAdapter -VMName $vmName).Count) + ' 個')
W-Info ('動態記憶體     : ' + (Get-VMMemory -VMName $vmName).DynamicMemoryEnabled)

Write-Host ''
Write-Host '下一步:' -ForegroundColor Yellow
Write-Host '  1. 啟動 VM,等 2-3 分鐘讓 Windows 完成驅動辨識'
Write-Host '  2. VM 裡開裝置管理員,顯示卡應為 NVIDIA GeForce RTX (不再是 Microsoft Basic Render)'
Write-Host '  3. 若 OpenGL 仍跳錯 (no driver / Microsoft Basic Render Driver),'
Write-Host '     在 VM 內跑 VM_NVFix_v1.0.bat 修補登錄檔'
Write-Host '  4. 在 VM 跑這個確認驅動有搬到位:'
Write-Host '       Test-Path C:\Windows\System32\nvoglv64.dll'
Write-Host '     回 True 才代表這次有搬到位'
Write-Host '  5. 偵測到的遊戲已搬到 VM 對應的 NC\ 或 NCSOFT\ 資料夾'
Write-Host '     首次執行可能需要在 VM 內補裝 VC++ Redist / DirectX'
Write-Host ''

$yn = Read-Host '要立即啟動 VM 嗎?(Y/N)'
if ($yn -match '^[Yy]') {
    try {
        Start-VM -Name $vmName -ErrorAction Stop
        W-OK ('已啟動 ' + $vmName)
    } catch {
        W-Err ('啟動失敗: ' + $_.Exception.Message)
    }
}

Write-Host ''
