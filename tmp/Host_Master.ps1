# =========================================================
#  Host_Master.ps1  -  Hyper-V GPU-PV 直通 + 顯卡驅動複製
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

W-Title 'GPU-PV 直通 + 驅動複製工具 v1.4'

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

    # .sys → drivers
    Get-ChildItem $gpuFolder.FullName -Filter '*.sys' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Copy-Item $_.FullName -Destination $destDrivers -Force -ErrorAction Stop
            $flatSys++
        } catch {}
    }

    # .dll → System32 (64-bit)
    Get-ChildItem $gpuFolder.FullName -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Copy-Item $_.FullName -Destination $destSystem32 -Force -ErrorAction Stop
            $flatDll++
        } catch {}
    }

    # .exe → System32
    Get-ChildItem $gpuFolder.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Copy-Item $_.FullName -Destination $destSystem32 -Force -ErrorAction Stop
            $flatExe++
        } catch {}
    }

    # 32-bit subfolder (NVIDIA 把 32-bit 放在子資料夾,通常叫 'x86' 或 'wow' 或 dll 命名 nvogl*32 在根目錄)
    # 先掃同資料夾根目錄底下名字含 "32" 的 dll → SysWOW64
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
W-OK ('攤平複製: ' + $flatDll + ' 個 DLL → System32, ' + `
       $flatExe + ' 個 EXE → System32, ' + `
       $flatSys + ' 個 SYS → System32\drivers, ' + `
       $flat32 + ' 個 32-bit DLL → SysWOW64')

# ---------------------------------------------------------
#  5c. 自我檢查 - 關鍵檔案是否到位
# ---------------------------------------------------------
W-Step 'v1.3: 自我檢查 OpenGL / KMD 關鍵檔案'
$checks = @(
    @{ Name = 'nvoglv64.dll (OpenGL ICD 64-bit)'; Path = (Join-Path $destSystem32 'nvoglv64.dll'); Critical = $true }
    @{ Name = 'nvoglv32.dll (OpenGL ICD 32-bit)'; Path = (Join-Path $destSysWOW64 'nvoglv32.dll'); Critical = $false }
    @{ Name = 'nvlddmkm.sys (Kernel Mode Driver)'; Path = (Join-Path $destDrivers 'nvlddmkm.sys'); Critical = $true }
    @{ Name = 'nvldumdx.dll (User Mode Driver)'; Path = (Join-Path $destSystem32 'nvldumdx.dll'); Critical = $true }
    @{ Name = 'nvapi64.dll (NVAPI)'; Path = (Join-Path $destSystem32 'nvapi64.dll'); Critical = $false }
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
#  5d. v1.4 新增: 複製 NCSOFT 遊戲資料夾 (Lineage Classic + Purple)
# ---------------------------------------------------------
W-Title 'v1.4: 複製 NCSOFT 遊戲資料夾'

$ncsoftSrcRoot = 'C:\Program Files (x86)\NCSOFT'
$ncsoftDstRoot = Join-Path $vmDrive 'Program Files (x86)\NCSOFT'
$gameFolders   = @('Lineage Classic', 'Purple')

if (-not (Test-Path $ncsoftSrcRoot)) {
    W-Warn ('來源不存在,略過: ' + $ncsoftSrcRoot)
} else {
    if (-not (Test-Path $ncsoftDstRoot)) {
        try {
            New-Item -Path $ncsoftDstRoot -ItemType Directory -Force | Out-Null
            W-OK ('建立目的資料夾: ' + $ncsoftDstRoot)
        } catch {
            W-Err ('無法建立目的資料夾: ' + $_.Exception.Message)
        }
    }

    # 先估算需要的總空間 + 顯示 VHDX 剩餘空間
    $totalSrcBytes = 0
    foreach ($name in $gameFolders) {
        $src = Join-Path $ncsoftSrcRoot $name
        if (Test-Path $src) {
            try {
                $sz = (Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
                if ($sz) { $totalSrcBytes += $sz }
            } catch {}
        }
    }
    $vol = $null
    try {
        $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction SilentlyContinue
        if ($vol) {
            W-Info ('VM 系統碟 ' + $vmDrive + ' 剩餘空間: {0:N2} GB / 總容量 {1:N2} GB' -f `
                ($vol.SizeRemaining / 1GB), ($vol.Size / 1GB))
        }
    } catch {}
    if ($totalSrcBytes -gt 0) {
        W-Info ('NCSOFT 來源資料夾總大小: {0:N2} GB' -f ($totalSrcBytes / 1GB))
        if ($vol -and $vol.SizeRemaining -lt ($totalSrcBytes * 1.05)) {
            W-Warn 'VM VHDX 剩餘空間可能不足,建議先擴充 VHDX 再複製'
        }
    }

    foreach ($name in $gameFolders) {
        $src = Join-Path $ncsoftSrcRoot $name
        $dst = Join-Path $ncsoftDstRoot $name

        if (-not (Test-Path $src)) {
            W-Warn ('找不到 ' + $src + ',略過')
            continue
        }

        $srcSizeGB = 0
        try {
            $srcSizeGB = [math]::Round(((Get-ChildItem $src -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB), 2)
        } catch {}
        W-Step ('複製 ' + $name + '  (約 ' + $srcSizeGB + ' GB) → ' + $dst)
        W-Info '檔案多時請耐心等候,robocopy 多執行緒搬運中...'

        # 用 robocopy 比 Copy-Item 快又穩;
        # /E   含子資料夾 (包含空的)
        # /R:1 /W:2  失敗時只重試 1 次,等 2 秒
        # /MT:16    16 條執行緒
        # /XJ       不跟 junction (避免無限遞迴)
        # /NFL /NDL 不列每個檔案/資料夾名稱
        # /NJH /NJS 不印 header / summary
        # /NC /NS   不印 class / size
        # /NP       不印 % progress
        $rcLog = Join-Path $env:TEMP ('robocopy_' + ($name -replace '\s+', '_') + '.log')
        $rcArgs = @($src, $dst, '/E', '/R:1', '/W:2', '/MT:16', '/XJ',
                    '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS', '/NP',
                    ('/LOG:' + $rcLog))

        $rcExit = 16
        try {
            & robocopy @rcArgs | Out-Null
            $rcExit = $LASTEXITCODE
        } catch {
            W-Err ('robocopy 執行失敗: ' + $_.Exception.Message)
            continue
        }

        # robocopy exit code: 0~7 都算正常 (0=沒事, 1=有複製, 2=多餘, 3=複製+多餘, ...; >=8 才是錯誤)
        if ($rcExit -lt 8) {
            $tag = switch ($rcExit) {
                0 { '無變更' }
                1 { '複製成功' }
                2 { '目的有多餘檔(已忽略)' }
                3 { '複製成功+目的有多餘檔' }
                default { ('code=' + $rcExit) }
            }
            W-OK ($name + ' 完成 (' + $tag + ')')
        } else {
            W-Err ($name + ' 複製失敗 (robocopy code=' + $rcExit + '),log: ' + $rcLog)
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
W-Title '完成 - GPU-PV 直通配置 v1.4'

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
Write-Host '  3. 開遊戲測試 OpenGL 是否還跳錯'
Write-Host '  4. 若仍跳 Cannot create OpenGL context, 在 VM 跑:'
Write-Host '       Test-Path C:\Windows\System32\nvoglv64.dll'
Write-Host '     回 True 才代表這次有搬到位'
Write-Host '  5. NCSOFT 遊戲已搬到 VM 的 C:\Program Files (x86)\NCSOFT\'
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
