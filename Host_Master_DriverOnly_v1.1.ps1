# =========================================================
#  Host_Master_DriverOnly_v1.1.ps1
#  Hyper-V GPU-PV 直通 + 顯卡驅動複製 (不搬遊戲版)
#
#  基底 = Host_Master_DriverOnly_v1.0 (= Host_Master_v1.7 去掉 5d 搬遊戲),
#  GPU-PV 參數 / VHDX 掛載 / INF 補漏流程不變。
#
#  v1.1 (vs v1.0) - 針對「VM 內列得出顯示卡、但 D3D12CreateDevice 失敗」的版本不符:
#    + 只搬「主機現用版本」那一個顯示驅動套件。
#      v1.0 會把 DriverStore 裡每個含 nvoglv64.dll 的套件全部攤平進 VM System32,
#      後複製的蓋前面的、又不排版本 → 主機更新過驅動沒清舊套件時可能搬到舊版。
#      現在用 nvlddmkm.sys 的檔案版本比對 Win32_VideoController 回報的現用版本;
#      對不上就取最高版並大聲警告;其餘顯示套件一律不搬 (5a 整包複製也略過)。
#    + 5b-2 / 5b-3 找檔順序:選中套件 → 主機 System32 → 其他 nv* 套件 → Program Files。
#    + 4. 加分區前印「主機可分割 GPU 數 vs VM 現有介面卡數」抓掛兩次;
#      配額寫入失敗會報、成功後讀回印出;結束時介面卡數不是 1 就 [X]。
#    + 5c 自我檢查加「版本比對」:VM 內 nvlddmkm.sys / nvoglv64.dll / nvldumdx.dll /
#      HostDriverStore 副本,逐檔比對來源套件同名檔的版本,不符就 [X]。
#    + 參數 (對齊 GPU_Remove):-Preview 只掃主機+列 VM,不動任何東西;
#      -VMName 跳過選單;-Yes 所有 Y/N 一律當 Y。.bat 會把參數原樣轉給本檔。
#    + -CleanOld / -NoCleanOld:掛載 VHDX 後、搬運前,先清掉 VM 內既有的 NVIDIA 驅動檔
#      = 乾淨重裝 (HostDriverStore\FileRepository\nv* 整包 + System32/SysWOW64 攤平的
#       nv*.dll/exe + drivers\nv*.sys;保留 Windows 內建的 nvraid.sys / nvstor.sys,那是
#       boot-start 儲存驅動,不是本工具搬進去的)。
#      -CleanOld = 清、不問;-NoCleanOld = 不清、不問;兩個都沒帶 = 在該步驟問一次
#      (-Yes 會自動答 Y,所以 -Yes 又不想清就要加 -NoCleanOld)。
#      (不用 -CleanOld:$false 是因為 .bat 走 powershell -File,switch 吃不到 :$false)
#
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
# MMIO 配置 (給 NVIDIA 驅動的 PCI BAR 位址空間)
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

W-Title 'GPU-PV 直通 + 驅動複製工具 DriverOnly v1.1 (不搬遊戲)'
W-Info ("MMIO Low/High = ${MMIO_LOW_GB}GB / ${MMIO_HIGH_GB}GB  |  GPU 配額 = ${GPU_QUOTA_PCT}%")
if ($Preview) { W-Warn '-Preview 模式:只掃描主機與 VM 清單,不做任何變更' }
if ($CleanOld -and $NoCleanOld) {
    W-Err '-CleanOld 與 -NoCleanOld 不能同時使用'
    exit 1
}
if ($CleanOld)   { W-Info '-CleanOld:搬運前會先清掉 VM 內既有 NVIDIA 驅動檔 (乾淨重裝)' }
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

# 用「裡面有 nvoglv64.dll」判定哪些資料夾是顯示驅動套件
# (新版 NVIDIA 用 nvmdsi.inf 命名,舊版用 nvami.inf / nvlddmkm.inf,
#  不能用 nv* 暴力 filter 否則 nvhda nvvad 全進來)
W-Step '搜尋顯示驅動套件 (含 nvoglv64.dll)'
$repoRoot = "$env:WinDir\System32\DriverStore\FileRepository"
$candidates = @(Get-ChildItem $repoRoot -Filter 'nv*.inf_amd64_*' -Directory -ErrorAction SilentlyContinue)
$dispPkgs = @()
foreach ($c in $candidates) {
    if (Test-Path (Join-Path $c.FullName 'nvoglv64.dll')) {
        $dispPkgs += [PSCustomObject]@{
            Folder = $c
            Name   = $c.Name
            KmdVer = (Get-FileVer (Join-Path $c.FullName 'nvlddmkm.sys'))
        }
    }
}
if ($dispPkgs.Count -eq 0) {
    W-Err '在 DriverStore 找不到包含 nvoglv64.dll 的資料夾'
    W-Info '請先在主機安裝 NVIDIA 正式驅動 (GeForce / Studio Driver) 再跑本工具'
    W-Info '注意: 只裝 nForce 晶片組或音效驅動是不夠的'
    exit 1
}

# 主機現用驅動版本 (Win32_VideoController 回報的就是正在跑的那個)
$hostGpu = $null
$hostVer = $null
try {
    $hostGpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX' } | Select-Object -First 1
    if ($hostGpu -and $hostGpu.DriverVersion) { $hostVer = [version]$hostGpu.DriverVersion }
} catch {}
if ($hostGpu) {
    W-OK ('主機顯示卡: ' + $hostGpu.Name + '  現用驅動版本: ' + $hostGpu.DriverVersion)
} else {
    W-Warn '主機沒有回報 NVIDIA 顯示卡 (Win32_VideoController),無法比對現用版本'
}

W-OK ('找到顯示驅動套件: ' + $dispPkgs.Count + ' 個')
foreach ($p in $dispPkgs) {
    $tag = if ($p.KmdVer) { ' [KMD ' + $p.KmdVer + ']' } else { ' [缺 KMD!]' }
    W-Info ('  ' + $p.Name + $tag)
}

# 挑一個:①版本 = 主機現用 ②否則最高版 (缺 nvlddmkm.sys 的永不選)
$withKmd = @($dispPkgs | Where-Object { $_.KmdVer })
if ($withKmd.Count -eq 0) {
    W-Err '所有顯示驅動套件都缺 nvlddmkm.sys,無法搬運'
    exit 1
}
$gpuPkg = $null
$pickReason = ''
if ($hostVer) {
    $gpuPkg = $withKmd | Where-Object { $_.KmdVer -eq $hostVer } | Select-Object -First 1
    if ($gpuPkg) { $pickReason = '版本 = 主機現用 ' + $hostVer }
}
if (-not $gpuPkg) {
    $gpuPkg = $withKmd | Sort-Object KmdVer -Descending | Select-Object -First 1
    $pickReason = '取最高版 ' + $gpuPkg.KmdVer
    if ($hostVer) {
        W-Warn ('沒有套件的版本等於主機現用 ' + $hostVer + ',改取最高版。搬進 VM 後可能與主機不符,請先確認主機驅動狀態')
    } else {
        W-Warn '無法比對主機現用版本,改取最高版'
    }
}
$gpuFolder = $gpuPkg.Folder
W-OK ('選用套件: ' + $gpuPkg.Name + '  (' + $pickReason + ')')
$skipped = @($dispPkgs | Where-Object { $_.Name -ne $gpuPkg.Name })
foreach ($s in $skipped) {
    $sv = if ($s.KmdVer) { [string]$s.KmdVer } else { '缺 KMD' }
    W-Info ('  略過其他顯示套件: ' + $s.Name + ' [' + $sv + ']  (v1.0 會連這個一起攤平,v1.1 不搬)')
}

# HostDriverStore 整包複製清單 = 所有 nv* 資料夾,但顯示套件只留選中的那個
$skipNames = @($skipped | ForEach-Object { $_.Name })
$nvRepo = @($candidates | Where-Object { $skipNames -notcontains $_.Name })
W-Info ('HostDriverStore 整包複製清單: ' + $nvRepo.Count + ' 個 nv* 資料夾 (含選中的顯示套件 + 非顯示的 nv* 套件)')

# 主機可分割 GPU (需要系統管理員;讀不到只警告)
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
#  -Preview:列出 Gen2 VM 與分區介面卡數就結束,不做任何變更
# =========================================================
if ($Preview) {
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
#  5-pre. (可選 -CleanOld) 清掉 VM 內既有的 NVIDIA 驅動檔,再重搬 = 乾淨重裝
#  清理範圍同 GPU_Remove_v1.0 的步驟 5:
#    - Windows\System32\HostDriverStore\FileRepository\nv* 整包
#    - System32 / SysWOW64 攤平的 nv*.dll / nv*.exe
#    - System32\drivers 的 nv*.sys
#  但保留 Windows 內建的 nvraid.sys / nvstor.sys (nForce 儲存驅動,Start=0 boot-start,
#  nvstor 還是 ErrorControl=Critical;不是本工具搬進去的,刪了有開不了機的風險)
# ---------------------------------------------------------
function Remove-OldNvFiles([string]$root) {
    $protectedSys = @('nvraid.sys', 'nvstor.sys', 'nvstor64.sys')
    $result = [ordered]@{ Folders = 0; Files = 0; Skipped = 0; Failed = 0 }

    # HostDriverStore 內 nv* 整包
    $hds = Join-Path $root 'Windows\System32\HostDriverStore\FileRepository'
    if (Test-Path $hds) {
        foreach ($dirItem in @(Get-ChildItem $hds -Filter 'nv*' -Directory -ErrorAction SilentlyContinue)) {
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

    # 攤平檔案 (只刪 nv* 開頭;-Filter 有 8.3 短檔名誤配問題,再用副檔名精確過濾一次)
    $targets = @(
        @{ Dir = (Join-Path $root 'Windows\System32');         Filters = @('nv*.dll', 'nv*.exe') }
        @{ Dir = (Join-Path $root 'Windows\SysWOW64');         Filters = @('nv*.dll') }
        @{ Dir = (Join-Path $root 'Windows\System32\drivers'); Filters = @('nv*.sys') }
    )
    foreach ($t in $targets) {
        if (-not (Test-Path $t.Dir)) { continue }
        foreach ($f in $t.Filters) {
            $ext = [System.IO.Path]::GetExtension($f)
            foreach ($fileItem in @(Get-ChildItem $t.Dir -Filter $f -File -ErrorAction SilentlyContinue)) {
                if ($fileItem.Extension -ne $ext) { continue }
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
    W-Warn '可以先清掉 VM 內既有的 NVIDIA 驅動檔再重搬 (乾淨重裝;範圍同 GPU_Remove_v1.0):'
    W-Info '  - Windows\System32\HostDriverStore\FileRepository\nv* 整包'
    W-Info '  - System32 / SysWOW64 攤平的 nv*.dll / nv*.exe'
    W-Info '  - System32\drivers 的 nv*.sys (Windows 內建 nvraid / nvstor 會保留)'
    W-Info '換過顯示卡、或 VM 內曾看到兩張同名卡的機器,建議清。'
    $doClean = Ask-YN '要先清掉舊驅動檔嗎?'
}
if ($doClean) {
    W-Step '清除 VM 內既有 NVIDIA 驅動檔 (-CleanOld)'
    try {
        $cr = Remove-OldNvFiles $vmDrive
        W-OK ('已刪除 ' + $cr.Folders + ' 個 HostDriverStore nv* 資料夾、' + $cr.Files + ' 個攤平 nv* 檔;保留內建 ' + $cr.Skipped + ' 個;失敗 ' + $cr.Failed + ' 個')
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
#  5a. HostDriverStore 整包複製 (顯示套件只搬選中的那個)
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
foreach ($folder in $nvRepo) {
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
    if ($hdsFailNames -contains $gpuPkg.Name) {
        W-Err '  失敗的包含選中的顯示套件,VM 開機後 GPU 一定不能用'
    }
    W-Err '  結束時會回 exit 1;請關掉佔用 VHDX 的程式後重跑本工具'
}

# VM 內若殘留主機已沒有的舊顯示套件,列出來讓人知道 (不主動刪;-CleanOld 會清)
try {
    $vmDispOld = @(Get-ChildItem $destDriverRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { (Test-Path (Join-Path $_.FullName 'nvoglv64.dll')) -and ($_.Name -ne $gpuPkg.Name) })
    foreach ($o in $vmDispOld) {
        $ov = Get-FileVer (Join-Path $o.FullName 'nvlddmkm.sys')
        W-Info ('  VM 內殘留舊顯示套件 (不影響,主機以名稱指定要用哪個;-CleanOld 會清): ' + $o.Name + ' [' + $ov + ']')
    }
} catch {}

# ---------------------------------------------------------
#  5b. 從「選中的」顯示驅動套件攤平複製到 System32
# ---------------------------------------------------------
W-Step ('從選中套件攤平到 System32 / drivers: ' + $gpuPkg.Name)
$destSystem32 = Join-Path $vmDrive 'Windows\System32'
$destSysWOW64 = Join-Path $vmDrive 'Windows\SysWOW64'
$destDrivers  = Join-Path $vmDrive 'Windows\System32\drivers'

if (-not (Test-Path $destDrivers)) {
    New-Item -Path $destDrivers -ItemType Directory -Force | Out-Null
}

$flatDll = 0; $flatExe = 0; $flatSys = 0; $flat32 = 0; $flatFail = 0

# .sys -> drivers
Get-ChildItem $gpuFolder.FullName -Filter '*.sys' -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Copy-Item $_.FullName -Destination $destDrivers -Force -ErrorAction Stop
        $flatSys++
    } catch { $flatFail++; W-Warn ('  攤平失敗: ' + $_.Exception.Message) }
}

# .dll -> System32 (64-bit)
Get-ChildItem $gpuFolder.FullName -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Copy-Item $_.FullName -Destination $destSystem32 -Force -ErrorAction Stop
        $flatDll++
    } catch { $flatFail++; W-Warn ('  攤平失敗: ' + $_.Exception.Message) }
}

# .exe -> System32
Get-ChildItem $gpuFolder.FullName -Filter '*.exe' -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Copy-Item $_.FullName -Destination $destSystem32 -Force -ErrorAction Stop
        $flatExe++
    } catch { $flatFail++; W-Warn ('  攤平失敗: ' + $_.Exception.Message) }
}

# 32-bit: 先掃根目錄名字含 "32" 的 dll -> SysWOW64
Get-ChildItem $gpuFolder.FullName -Filter '*32.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        Copy-Item $_.FullName -Destination $destSysWOW64 -Force -ErrorAction Stop
        $flat32++
    } catch { $flatFail++; W-Warn ('  攤平失敗: ' + $_.Exception.Message) }
}

# 也掃子資料夾找 32-bit (有些版本放在 'x86_32' 之類)
$sub32 = Get-ChildItem $gpuFolder.FullName -Directory -ErrorAction SilentlyContinue |
         Where-Object { $_.Name -match '32|x86|wow' }
foreach ($s in $sub32) {
    Get-ChildItem $s.FullName -Filter '*.dll' -File -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Copy-Item $_.FullName -Destination $destSysWOW64 -Force -ErrorAction Stop
            $flat32++
        } catch { $flatFail++; W-Warn ('  攤平失敗: ' + $_.Exception.Message) }
    }
}
W-OK ('攤平複製: ' + $flatDll + ' 個 DLL -> System32, ' + `
       $flatExe + ' 個 EXE -> System32, ' + `
       $flatSys + ' 個 SYS -> System32\drivers, ' + `
       $flat32 + ' 個 32-bit DLL -> SysWOW64')
if ($flatFail -gt 0) {
    W-Warn ('攤平複製有 ' + $flatFail + ' 個檔案失敗 (下面 5c 的關鍵檔與版本比對會揭露是否傷到要害)')
}

# ---------------------------------------------------------
#  5b-2. 補搬 modern OpenGL / CUDA runtime 必要 DLL
#  R535+ 之後的 NVIDIA OpenGL ICD (nvoglv64.dll) 初始化時會 LoadLibrary:
#    nvcuda.dll / nvcompiler.dll / nvfatbinaryLoader.dll / nvptxJitCompiler.dll
#  任一個缺 -> wglCreateContext 失敗 -> "cannot opengl" / GLFW #65542
# ---------------------------------------------------------
W-Step '補搬 CUDA runtime / NVENC / NVFBC (modern OpenGL 相依)'

# 找一個 DLL 在主機的位置,找不到傳 $null
# 順序:選中套件 (與搬進 VM 的 KMD/UMD 同版) → 主機 System32 → 其他 nv* 套件 → Program Files
# (不再全域掃 DriverStore,避免撈到被略過的舊版顯示套件)
function Find-HostNvDll([string]$name) {
    # 1. 選中的顯示驅動套件 (含子資料夾)
    $hits = Get-ChildItem $gpuFolder.FullName -Filter $name -Recurse -File -ErrorAction SilentlyContinue
    if ($hits) { return $hits[0].FullName }
    # 2. 主機 System32 (現用驅動的即時副本)
    $direct = Join-Path "$env:WinDir\System32" $name
    if (Test-Path $direct) { return $direct }
    # 3. 其他要搬的 nv* 套件 (已排除非選中的顯示套件)
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
#  5c. 自我檢查 - 關鍵檔案是否到位 + 版本是否等於來源套件
# ---------------------------------------------------------
W-Step '自我檢查 OpenGL / KMD 關鍵檔案'
$checks = @(
    @{ Name = 'nvoglv64.dll (OpenGL ICD 64-bit)';   Path = (Join-Path $destSystem32 'nvoglv64.dll');           Critical = $true  }
    @{ Name = 'nvoglv32.dll (OpenGL ICD 32-bit)';   Path = (Join-Path $destSysWOW64 'nvoglv32.dll');           Critical = $false }
    @{ Name = 'nvlddmkm.sys (Kernel Mode Driver)';  Path = (Join-Path $destDrivers  'nvlddmkm.sys');           Critical = $true  }
    @{ Name = 'nvldumdx.dll (User Mode Driver)';    Path = (Join-Path $destSystem32 'nvldumdx.dll');           Critical = $true  }
    @{ Name = 'nvapi64.dll (NVAPI)';                Path = (Join-Path $destSystem32 'nvapi64.dll');            Critical = $false }
    # modern OpenGL ICD 相依
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

# 版本比對:VM 內的檔案版本必須等於「來源套件同名檔」的版本 (這次的病灶就是版本不符)
W-Step ('版本比對 (來源套件 ' + $gpuPkg.Name + ',KMD ' + $gpuPkg.KmdVer + ')')
$vmPkgDir = Join-Path $destDriverRoot $gpuPkg.Name
$verChecks = @(
    @{ Name = 'System32\drivers\nvlddmkm.sys';          VmPath = (Join-Path $destDrivers  'nvlddmkm.sys'); SrcPath = (Join-Path $gpuFolder.FullName 'nvlddmkm.sys') }
    @{ Name = 'System32\nvoglv64.dll';                  VmPath = (Join-Path $destSystem32 'nvoglv64.dll'); SrcPath = (Join-Path $gpuFolder.FullName 'nvoglv64.dll') }
    @{ Name = 'System32\nvldumdx.dll';                  VmPath = (Join-Path $destSystem32 'nvldumdx.dll'); SrcPath = (Join-Path $gpuFolder.FullName 'nvldumdx.dll') }
    # HostDriverStore 那份不是備份:GPU-PV 的 VM 就是從這個資料夾載 UMD,版本不對遊戲一定壞
    @{ Name = 'HostDriverStore\<套件>\nvlddmkm.sys (VM 實際載入位置)'; VmPath = (Join-Path $vmPkgDir 'nvlddmkm.sys'); SrcPath = (Join-Path $gpuFolder.FullName 'nvlddmkm.sys') }
)
$verMismatch = 0
foreach ($vc in $verChecks) {
    $srcV = Get-FileVer $vc.SrcPath
    $vmV  = Get-FileVer $vc.VmPath
    if (-not $srcV) {
        W-Warn ('  來源套件沒有 ' + $vc.Name + ',跳過比對')
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

if ($missingCritical -gt 0 -or $verMismatch -gt 0 -or $hdsFail -gt 0) {
    W-Warn ('有 ' + $missingCritical + ' 個關鍵檔案缺失、' + $verMismatch + ' 個版本不符/缺檔、' + $hdsFail + ' 個 HostDriverStore 套件沒複製成功,VM 開機後可能仍無法建立 D3D12 / OpenGL')
    W-Info '請檢查主機 NVIDIA 驅動是否完整 (跑 GeForce Experience 或 NVIDIA App 重新安裝),或關掉佔用 VHDX 的程式後重跑'
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
W-Title '完成 - GPU-PV 直通配置 DriverOnly v1.1 (未搬任何遊戲)'

Write-Host ''
Write-Host '目前 VM 狀態:' -ForegroundColor White
$vmNow = Get-VM -Name $vmName
$gpuNow = @(Get-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue).Count
W-Info ('名稱           : ' + $vmNow.Name)
W-Info ('狀態           : ' + $vmNow.State)
W-Info ('GPU 分區介面卡 : ' + $gpuNow + ' 個 (應為 1)')
W-Info ('動態記憶體     : ' + (Get-VMMemory -VMName $vmName).DynamicMemoryEnabled)
W-Info ('搬入驅動套件   : ' + $gpuPkg.Name + '  [' + $gpuPkg.KmdVer + ']')
W-Info ('清除舊驅動檔   : ' + $(if ($doClean) { '有 (-CleanOld,乾淨重裝)' } else { '無 (只覆蓋同名檔)' }))
W-Info ('HostDriverStore : 成功 ' + $hdsOK + ' 個 / 失敗 ' + $hdsFail + ' 個套件;攤平失敗 ' + $flatFail + ' 檔')

Write-Host ''
Write-Host '下一步:' -ForegroundColor Yellow
Write-Host '  1. 啟動 VM,等 2-3 分鐘讓 Windows 完成驅動辨識'
Write-Host '  2. VM 裡開裝置管理員,顯示卡應為「一張」NVIDIA GeForce RTX (不再是兩張同名卡,'
Write-Host '     也不是 Microsoft Basic Render)'
Write-Host '  3. VM 內以系統管理員跑 D3D12 smoke test (或 dxdiag 顯示卡分頁),'
Write-Host '     確認對 NVIDIA 卡能建立 D3D12 裝置 (FL11_0 OK),再開遊戲'
Write-Host '  4. 若 OpenGL 仍跳錯 (no driver / Microsoft Basic Render Driver),'
Write-Host '     在 VM 內跑 VM_NVFix_v1.0.bat 修補登錄檔'
Write-Host '  5. 在 VM 跑這個確認驅動有搬到位:'
Write-Host '       Test-Path C:\Windows\System32\nvoglv64.dll'
Write-Host '     回 True 才代表這次有搬到位'
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
if ($gpuNow -eq 1 -and $missingCritical -eq 0 -and $verMismatch -eq 0 -and $hdsFail -eq 0) { exit 0 } else { exit 1 }
