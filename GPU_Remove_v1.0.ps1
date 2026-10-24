# =========================================================
#  GPU_Remove_v1.0.ps1  -  Hyper-V GPU-PV 直通「移除」工具
#  反向還原 Host_Master v1.7 做過的三件事:
#    1. 移除 GPU 分區介面卡 (Remove-VMGpuPartitionAdapter)
#    2. 還原 VM 的 MMIO / Cache 參數為 Hyper-V 預設值
#       (Low 128MB / High 512MB / GuestControlledCacheTypes=False)
#    3. (可選) 掛載 VHDX,清掉當初複製進去的 NVIDIA 驅動檔
#       (HostDriverStore\FileRepository\nv* 整包 +
#        System32 / SysWOW64 / drivers 攤平的 nv*.dll/exe/sys)
#
#  不會動到的東西 (刻意保留,要改請自己跑對應指令):
#    - 動態記憶體 / 自動檢查點 / AutomaticStopAction (非 GPU 專屬設定)
#    - 5d 複製進 VM 的 NCSOFT 遊戲資料夾 (太大且與 GPU 無關)
#
#  參數 (給自動化用;不帶參數 = 互動模式):
#    -VMName <名稱>     直接指定 VM,跳過選單
#    -Yes               所有 Y/N 詢問一律當 Y (含關機與驅動清理)
#    -SkipDriverClean   跳過步驟 3 的 VHDX 驅動清理
# =========================================================
param(
    [string]$VMName = '',
    [switch]$Yes,
    [switch]$SkipDriverClean
)

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# Hyper-V Gen2 VM 預設 MMIO 值 (還原目標)
$DEFAULT_MMIO_LOW  = [uint64](128MB)
$DEFAULT_MMIO_HIGH = [uint64](512MB)

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

W-Title 'GPU-PV 直通移除工具 v1.0'

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

# =========================================================
#  1. 選擇目標 VM
# =========================================================
if ($VMName) {
    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        W-Err ('找不到 VM: ' + $VMName)
        exit 1
    }
} else {
    W-Step '選擇目標 VM'
    $vms = @(Get-VM | Where-Object { $_.Generation -eq 2 } | Sort-Object Name)
    if ($vms.Count -eq 0) {
        W-Err '找不到 Generation 2 VM'
        exit 1
    }
    Write-Host ''
    Write-Host 'Gen 2 VM 清單 (GPU 欄 = 現有 GPU 分區介面卡數):' -ForegroundColor White
    for ($i = 0; $i -lt $vms.Count; $i++) {
        $v = $vms[$i]
        $gpuN = @(Get-VMGpuPartitionAdapter -VMName $v.Name -ErrorAction SilentlyContinue).Count
        $color = if ($gpuN -gt 0) { 'Green' } else { 'Gray' }
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
#  2. 確認 VM 已關機 (移除分區與掛 VHDX 都需要)
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

# =========================================================
#  3. 移除 GPU 分區介面卡
# =========================================================
W-Title '移除 GPU 分區介面卡'
$adapters = @(Get-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue)
if ($adapters.Count -eq 0) {
    W-Info '此 VM 沒有 GPU 分區介面卡,略過'
} else {
    foreach ($a in $adapters) {
        W-Step ('移除分區介面卡 Id: ' + $a.Id)
        Remove-VMGpuPartitionAdapter -VMName $vmName -AdapterId $a.Id -ErrorAction Stop
    }
    W-OK ('已移除 ' + $adapters.Count + ' 個 GPU 分區介面卡')
}

# =========================================================
#  4. 還原 MMIO / Cache 參數為 Hyper-V 預設
# =========================================================
W-Step '還原 MMIO / Cache 參數 (Low 128MB / High 512MB / Cache=False)'
try {
    Set-VM -Name $vmName -GuestControlledCacheTypes $false
    Set-VM -Name $vmName -LowMemoryMappedIoSpace $DEFAULT_MMIO_LOW
    Set-VM -Name $vmName -HighMemoryMappedIoSpace $DEFAULT_MMIO_HIGH
    W-OK 'MMIO / Cache 已還原為預設值'
} catch { W-Err ('失敗: ' + $_.Exception.Message) }

# =========================================================
#  5. (可選) 掛載 VHDX 清理 NVIDIA 驅動檔
# =========================================================
$doClean = $false
if (-not $SkipDriverClean) {
    Write-Host ''
    W-Warn '接下來可以掛載 VHDX,清掉當初複製進 VM 的 NVIDIA 驅動檔:'
    W-Info '  - Windows\System32\HostDriverStore\FileRepository\nv* 整包'
    W-Info '  - System32 / SysWOW64 攤平的 nv*.dll / nv*.exe'
    W-Info '  - System32\drivers 的 nv*.sys'
    W-Info '不清也可以正常運作,只是 VHDX 會留幾百 MB 的無用驅動檔。'
    $doClean = Ask-YN '要清理 VHDX 內的 NVIDIA 驅動檔嗎?'
}

if ($doClean) {
    W-Title 'VHDX 掛載 + 驅動清理'
    $hdd = Get-VMHardDiskDrive -VMName $vmName | Select-Object -First 1
    if (-not $hdd) {
        W-Warn '這個 VM 沒有掛 VHDX,略過清理'
    } else {
        $vhdPath = $hdd.Path
        W-Info ('VHDX 路徑: ' + $vhdPath)

        $mountedDisk = $null
        $vmDrive = $null
        try {
            W-Step '掛載 VHDX'
            $mountedDisk = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
            Start-Sleep -Seconds 2
            $parts = @(Get-Partition -DiskNumber $mountedDisk.DiskNumber | Where-Object { $_.Type -eq 'Basic' -or $_.Type -eq 'IFS' -or $_.Size -gt 10GB } | Sort-Object Size -Descending)
            if ($parts.Count -eq 0) { throw '找不到可掛載的分區' }
            $sysPart = $parts[0]
            if (-not $sysPart.DriveLetter) {
                Add-PartitionAccessPath -DiskNumber $mountedDisk.DiskNumber -PartitionNumber $sysPart.PartitionNumber -AssignDriveLetter
                Start-Sleep -Seconds 1
                $sysPart = Get-Partition -DiskNumber $mountedDisk.DiskNumber -PartitionNumber $sysPart.PartitionNumber
            }
            $vmDrive = $sysPart.DriveLetter + ':'
            W-OK ('VHDX 已掛載到 ' + $vmDrive)

            if (-not (Test-Path (Join-Path $vmDrive 'Windows\System32'))) {
                throw ('找不到 ' + $vmDrive + '\Windows\System32,這個 VHDX 可能不是 Windows 系統碟')
            }

            # 5a. HostDriverStore 內 nv* 整包刪除
            $hds = Join-Path $vmDrive 'Windows\System32\HostDriverStore\FileRepository'
            $hdsRemoved = 0
            if (Test-Path $hds) {
                Get-ChildItem $hds -Filter 'nv*' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    W-Step ('刪除 HostDriverStore: ' + $_.Name)
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    $hdsRemoved++
                }
                # FileRepository 清空後把空殼一起收掉
                if (-not (Get-ChildItem $hds -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item (Join-Path $vmDrive 'Windows\System32\HostDriverStore') -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            W-OK ('HostDriverStore 已刪除 ' + $hdsRemoved + ' 個 nv* 資料夾')

            # 5b. 攤平檔案清除 (只刪 nv* 開頭,不碰其他系統檔)
            $targets = @(
                @{ Dir = (Join-Path $vmDrive 'Windows\System32');         Filters = @('nv*.dll','nv*.exe') }
                @{ Dir = (Join-Path $vmDrive 'Windows\SysWOW64');         Filters = @('nv*.dll') }
                @{ Dir = (Join-Path $vmDrive 'Windows\System32\drivers'); Filters = @('nv*.sys') }
            )
            $flatRemoved = 0
            foreach ($t in $targets) {
                if (-not (Test-Path $t.Dir)) { continue }
                foreach ($f in $t.Filters) {
                    Get-ChildItem $t.Dir -Filter $f -File -ErrorAction SilentlyContinue | ForEach-Object {
                        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                        $flatRemoved++
                    }
                }
            }
            W-OK ('攤平驅動檔已刪除 ' + $flatRemoved + ' 個 (nv*.dll / nv*.exe / nv*.sys)')

            # 5c. 自我檢查:關鍵檔案應該都不在了
            W-Step '自我檢查 (以下應全部為「已清除」)'
            $checks = @(
                (Join-Path $vmDrive 'Windows\System32\nvoglv64.dll'),
                (Join-Path $vmDrive 'Windows\System32\drivers\nvlddmkm.sys'),
                (Join-Path $vmDrive 'Windows\System32\nvcuda.dll'),
                (Join-Path $vmDrive 'Windows\System32\HostDriverStore')
            )
            $leftover = 0
            foreach ($c in $checks) {
                if (Test-Path $c) {
                    W-Warn ('  仍存在: ' + $c)
                    $leftover++
                } else {
                    W-OK ('  已清除: ' + $c)
                }
            }
            if ($leftover -gt 0) {
                W-Warn ('有 ' + $leftover + ' 項未清乾淨 (可能被鎖定),可重跑一次本工具')
            }
        } catch {
            W-Err ('VHDX 清理失敗: ' + $_.Exception.Message)
        } finally {
            if ($mountedDisk) {
                W-Step '卸載 VHDX'
                try {
                    Dismount-VHD -Path $vhdPath -ErrorAction Stop
                    W-OK '卸載完成'
                } catch {
                    W-Err ('卸載失敗(可能被佔用): ' + $_.Exception.Message)
                    W-Info '請關閉檔案總管視窗後手動執行: Dismount-VHD -Path "' + $vhdPath + '"'
                }
            }
        }
    }
} else {
    W-Info '略過 VHDX 驅動清理'
}

# =========================================================
#  6. 結尾
# =========================================================
W-Title '完成 - GPU-PV 直通已移除'
$vmNow = Get-VM -Name $vmName
$gpuLeft = @(Get-VMGpuPartitionAdapter -VMName $vmName -ErrorAction SilentlyContinue).Count
W-Info ('名稱           : ' + $vmNow.Name)
W-Info ('狀態           : ' + $vmNow.State)
W-Info ('GPU 分區介面卡 : ' + $gpuLeft + ' 個 (應為 0)')
W-Info ('LowMMIO        : {0:N0} MB (預設 128)' -f ((Get-VM -Name $vmName).LowMemoryMappedIoSpace / 1MB))
W-Info ('HighMMIO       : {0:N0} MB (預設 512)' -f ((Get-VM -Name $vmName).HighMemoryMappedIoSpace / 1MB))

Write-Host ''
Write-Host '說明:' -ForegroundColor Yellow
Write-Host '  1. VM 開機後顯示卡會回到 Microsoft Hyper-V 視訊卡 (基本顯示)'
Write-Host '  2. VM 裡裝置管理員若殘留 NVIDIA 裝置 (驚嘆號),右鍵解除安裝即可'
Write-Host '  3. 動態記憶體 / 檢查點 / AutomaticStopAction 未還原 (非 GPU 專屬設定)'
Write-Host '  4. 想重新啟用 GPU-PV,跑 Host_Master_v1.7.bat 即可'
Write-Host ''

if ($gpuLeft -eq 0) { exit 0 } else { exit 1 }
