# =========================================================
#  VM_Create_v1.0.ps1  -  Hyper-V 一鍵建立虛擬機工具
#
#  功能:
#    - 掃描指定資料夾內的 .vhdx,列清單讓你選編號
#    - 自動套用預設 (世代 / 記憶體 / vCPU / 網路交換器)
#    - VM 存放位置自動跟著 VHDX 所在資料夾
#    - 建完一台後可以連續再建下一台 (批次模式)
#
#  預設值 (可在下方常數區改):
#    掃描資料夾    : D:\Hyper-V\Disks  (找不到就改問你)
#    VM 世代       : 第 2 代 (Generation 2 / UEFI)
#    記憶體        : 6 GB,動態記憶體關閉
#    vCPU          : 4
#    網路交換器    : 第一個 External,沒有就用 Default Switch
#    VM 存放位置   : 跟所選 VHDX 同資料夾,沒有就用 Hyper-V 預設路徑
#
#  注意:
#    - 必須以系統管理員身分執行
#    - 必須已啟用 Hyper-V 功能 (Get-VM 可用)
# =========================================================

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# =========================================================
#  使用者可調整的預設值
# =========================================================
$DEFAULT_DISK_FOLDER = 'C:\Hyperdisk'
$DEFAULT_GENERATION  = 2
$DEFAULT_MEMORY_GB   = 6
$DEFAULT_VCPU        = 4
$DEFAULT_DYNAMIC_MEM = $false   # 關閉動態記憶體
$PROMPT_TIMEOUT_SEC  = 5        # 每個提示倒數秒數

# =========================================================
#  Helper: 文字輸出
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

# =========================================================
#  Helper: 倒數預設值輸入 (照 VM_Master 風格)
# =========================================================
function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default,
        [int]$Seconds = 5
    )

    # 先把上一個提示殘留在輸入緩衝區的按鍵清掉,避免污染這次的輸入
    try {
        while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }
    } catch {
        # 沒互動環境就直接回預設
        Write-Host "$Prompt [預設=$Default]: (無互動環境) $Default" -ForegroundColor DarkGray
        return $Default
    }

    Write-Host "$Prompt [預設=$Default,${Seconds}秒後自動套用]: " -ForegroundColor White -NoNewline

    # 倒數期間每 100ms 檢查一次是否有按鍵;偵測到第一個按鍵就跳出等待,進入 ReadLine 完整收這一行
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if ([Console]::KeyAvailable) { break }
        Start-Sleep -Milliseconds 100
    }

    if (-not [Console]::KeyAvailable) {
        Write-Host "(超時) $Default" -ForegroundColor DarkGray
        return $Default
    }

    # ReadLine 會把已經緩衝的字元一起讀回來,並負責把後續 echo 到畫面
    $line = [Console]::ReadLine()
    if ($null -eq $line -or [string]::IsNullOrWhiteSpace($line)) {
        Write-Host "(預設) $Default" -ForegroundColor DarkGray
        return $Default
    }
    # 去掉控制字元 + 前後空白
    $line = ($line -replace '[\x00-\x1F\x7F]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { return $Default }
    return $line
}

# =========================================================
#  Helper: 純粹一行 ReadLine,沒倒數沒預設
# =========================================================
function Read-Plain([string]$Prompt) {
    Write-Host "$Prompt " -ForegroundColor White -NoNewline
    return ([Console]::ReadLine()).Trim()
}

# =========================================================
#  開場
# =========================================================
W-Title 'Hyper-V 一鍵建立虛擬機 v1.0'

Write-Host ''
Write-Host ' 流程:' -ForegroundColor White
Write-Host '   1. 輸入要掃描的 VHDX 資料夾 (預設 D:\Hyper-V\Disks)' -ForegroundColor Gray
Write-Host '   2. 從清單選一顆硬碟' -ForegroundColor Gray
Write-Host '   3. 確認名稱 / 記憶體 / vCPU / 交換器 (都有預設值)' -ForegroundColor Gray
Write-Host '   4. 自動建立 VM,完成後問是否要再建一台' -ForegroundColor Gray
Write-Host ''

# =========================================================
#  預檢:管理員權限 + Hyper-V 模組
# =========================================================
W-Step '預檢:管理員權限 + Hyper-V 環境'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] 'Administrator')
if (-not $isAdmin) {
    W-Err '需要系統管理員權限'
    W-Info '請用 .bat 啟動器重跑,它會自動檢查管理員權限'
    exit 1
}
W-OK '管理員權限 OK'

if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    W-Err 'Hyper-V 模組找不到 (Get-VM 不可用)'
    W-Info '請先用 EnableHyperV.bat 啟用 Hyper-V 並重開機'
    exit 1
}
try {
    $null = Get-VMHost -ErrorAction Stop
    W-OK 'Hyper-V 服務 OK'
} catch {
    W-Err "Hyper-V 服務無法存取: $($_.Exception.Message)"
    exit 1
}

# =========================================================
#  抓 Hyper-V 預設路徑 (備援用)
# =========================================================
$hyperVDefaultVMPath = (Get-VMHost).VirtualMachinePath
W-Info "Hyper-V 預設 VM 存放路徑: $hyperVDefaultVMPath"

# =========================================================
#  選擇網路交換器 (整支腳本只挑一次)
# =========================================================
W-Step '挑選網路交換器'
$switchName = $null
$extSwitch = Get-VMSwitch -ErrorAction SilentlyContinue |
    Where-Object { $_.SwitchType -eq 'External' } |
    Select-Object -First 1

if ($extSwitch) {
    $switchName = $extSwitch.Name
    W-OK "找到 External 交換器: $switchName"
} else {
    $defSwitch = Get-VMSwitch -Name 'Default Switch' -ErrorAction SilentlyContinue
    if ($defSwitch) {
        $switchName = 'Default Switch'
        W-OK '沒有 External,改用 Default Switch'
    } else {
        # 再退一步:抓任一個交換器
        $anySwitch = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($anySwitch) {
            $switchName = $anySwitch.Name
            W-Warn "Default Switch 也沒有,改用第一個可用的交換器: $switchName"
        } else {
            W-Warn '完全找不到可用的虛擬交換器,VM 將不接網卡'
            $switchName = ''
        }
    }
}

# =========================================================
#  問掃描資料夾
# =========================================================
W-Step '指定 VHDX 掃描資料夾'
$diskFolder = Read-WithDefault '請輸入要掃描的資料夾' $DEFAULT_DISK_FOLDER $PROMPT_TIMEOUT_SEC
if (-not (Test-Path -LiteralPath $diskFolder -PathType Container)) {
    W-Err "資料夾不存在: $diskFolder"
    exit 1
}

# =========================================================
#  主流程:批次建立 VM
# =========================================================
$vmCreatedCount = 0

while ($true) {
    Write-Host ''
    W-Title "建立第 $($vmCreatedCount + 1) 台 VM"

    # ---------- 掃描 VHDX (含子資料夾) ----------
    W-Step "掃描 $diskFolder (含子資料夾) 內的 .vhdx"
    $vhdxList = @(Get-ChildItem -LiteralPath $diskFolder -Filter '*.vhdx' -File -Recurse -ErrorAction SilentlyContinue |
                  Sort-Object FullName)
    if ($vhdxList.Count -eq 0) {
        W-Err "找不到任何 .vhdx 檔"
        break
    }

    # 抓所有「已被現有 VM 使用」的 VHDX 路徑,標註用
    $usedPaths = @()
    try {
        $usedPaths = Get-VM -ErrorAction SilentlyContinue |
                     Get-VMHardDiskDrive -ErrorAction SilentlyContinue |
                     Select-Object -ExpandProperty Path
    } catch {}

    Write-Host ''
    Write-Host ' 編號  狀態     大小      檔案路徑' -ForegroundColor White
    Write-Host (' ' + ('-' * 70)) -ForegroundColor DarkGray
    for ($i = 0; $i -lt $vhdxList.Count; $i++) {
        $f = $vhdxList[$i]
        $idx = '{0,3}' -f ($i + 1)
        $sizeGB = '{0,6:N1}GB' -f ($f.Length / 1GB)
        $inUse = $usedPaths -contains $f.FullName
        $tag = if ($inUse) { '[使用中]' } else { '[ 可用 ]' }
        $color = if ($inUse) { 'DarkYellow' } else { 'Green' }
        Write-Host (' [{0}] {1} {2}  {3}' -f $idx, $tag, $sizeGB, $f.FullName) -ForegroundColor $color
    }
    Write-Host ''

    # ---------- 選編號 ----------
    $pickRaw = Read-Plain "請輸入硬碟編號 (1-$($vhdxList.Count)),按 Enter 直接結束:"
    if ([string]::IsNullOrWhiteSpace($pickRaw)) {
        W-Info '使用者結束'
        break
    }
    $pick = 0
    if (-not [int]::TryParse($pickRaw, [ref]$pick) -or $pick -lt 1 -or $pick -gt $vhdxList.Count) {
        W-Err "編號無效: $pickRaw"
        continue
    }
    $vhdx = $vhdxList[$pick - 1]
    W-OK "選到: $($vhdx.FullName)"

    # ---------- 預檢 VHDX:差異磁碟的父磁碟是否存在 / 路徑是否乾淨 ----------
    try {
        $vhdInfo = Get-VHD -Path $vhdx.FullName -ErrorAction Stop
        W-Info ("VHDX 類型: {0} (大小 {1:N1}GB)" -f $vhdInfo.VhdType, ($vhdInfo.Size / 1GB))
        if ($vhdInfo.ParentPath) {
            W-Info "差異磁碟父磁碟: $($vhdInfo.ParentPath)"
            if (-not (Test-Path -LiteralPath $vhdInfo.ParentPath)) {
                W-Err "父磁碟不存在,無法掛載 (這就是 New-VM 拋『路徑非法』的常見原因)"
                W-Info "處理方式:把父磁碟還原回 $($vhdInfo.ParentPath),或重做一顆獨立 VHDX"
                continue
            }
        }
    } catch {
        W-Err "Get-VHD 失敗: $($_.Exception.Message)"
        W-Info '檔案可能損毀、被鎖住,或不是合法的 VHDX。跳過這一顆。'
        continue
    }

    # 在使用中的話再次確認
    if ($usedPaths -contains $vhdx.FullName) {
        W-Warn '這顆 VHDX 已被其他 VM 使用,若繼續會建立第二個 VM 共用同一顆磁碟 (可能造成資料毀損)'
        $go = Read-WithDefault '仍要繼續?(Y/N)' 'N' $PROMPT_TIMEOUT_SEC
        if ($go -notmatch '^[Yy]') { continue }
    }

    # ---------- VM 名稱 ----------
    $defaultName = $vhdx.BaseName
    $vmName = Read-WithDefault 'VM 名稱' $defaultName $PROMPT_TIMEOUT_SEC
    if ([string]::IsNullOrWhiteSpace($vmName)) { $vmName = $defaultName }

    # 名稱合法性檢查 (Hyper-V 會用名稱建子資料夾,所以套用 Windows 檔名規則)
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $badChar = $null
    foreach ($c in $invalidChars) { if ($vmName.IndexOf($c) -ge 0) { $badChar = $c; break } }
    if ($badChar) {
        $hex = '0x{0:X2}' -f [int]$badChar
        W-Err "VM 名稱含有不合法字元 ($hex),請改一個。跳過這一台。"
        continue
    }

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        W-Warn "已經有同名 VM: $vmName"
        $vmName = Read-Plain '請改個新名稱:'
        if ([string]::IsNullOrWhiteSpace($vmName)) { W-Err '名稱不能空白,跳過'; continue }
        if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) { W-Err '還是衝突,跳過'; continue }
    }

    # ---------- 記憶體 ----------
    $memRaw = Read-WithDefault '記憶體 GB' "$DEFAULT_MEMORY_GB" $PROMPT_TIMEOUT_SEC
    $memGB = 0
    if (-not [double]::TryParse($memRaw, [ref]$memGB) -or $memGB -le 0) {
        W-Warn "記憶體輸入無效,改用預設 $DEFAULT_MEMORY_GB GB"
        $memGB = $DEFAULT_MEMORY_GB
    }

    # ---------- vCPU ----------
    $cpuRaw = Read-WithDefault 'vCPU 核心數' "$DEFAULT_VCPU" $PROMPT_TIMEOUT_SEC
    $cpuCount = 0
    if (-not [int]::TryParse($cpuRaw, [ref]$cpuCount) -or $cpuCount -lt 1) {
        W-Warn "vCPU 輸入無效,改用預設 $DEFAULT_VCPU"
        $cpuCount = $DEFAULT_VCPU
    }

    # ---------- VM 存放路徑 ----------
    $vmPath = Split-Path -Parent $vhdx.FullName
    if (-not (Test-Path -LiteralPath $vmPath -PathType Container)) {
        W-Warn "VHDX 所在資料夾不可用,改用 Hyper-V 預設: $hyperVDefaultVMPath"
        $vmPath = $hyperVDefaultVMPath
    }

    # ---------- 摘要 ----------
    Write-Host ''
    W-Title '建立摘要'
    Write-Host (' VM 名稱      : {0}' -f $vmName)        -ForegroundColor White
    Write-Host (' 世代         : Generation {0}' -f $DEFAULT_GENERATION) -ForegroundColor White
    Write-Host (' 記憶體       : {0} GB (動態={1})' -f $memGB, $DEFAULT_DYNAMIC_MEM) -ForegroundColor White
    Write-Host (' vCPU         : {0}' -f $cpuCount)      -ForegroundColor White
    Write-Host (' 網路交換器   : {0}' -f $(if ($switchName) { $switchName } else { '(無)' })) -ForegroundColor White
    Write-Host (' VHDX (掛載)  : {0}' -f $vhdx.FullName) -ForegroundColor White
    Write-Host (' VM 存放位置  : {0}' -f $vmPath)        -ForegroundColor White
    Write-Host ''

    $confirm = Read-WithDefault '確認建立?(Y/N)' 'Y' $PROMPT_TIMEOUT_SEC
    if ($confirm -notmatch '^[Yy]') {
        W-Info '取消這一台'
    } else {
        # ---------- 真的建 ----------
        $newVMArgs = @{
            Name               = $vmName
            Generation         = [int]$DEFAULT_GENERATION
            MemoryStartupBytes = [int64]([double]$memGB * 1GB)
            VHDPath            = $vhdx.FullName
            Path               = $vmPath
            ErrorAction        = 'Stop'
        }
        if ($switchName) { $newVMArgs.SwitchName = $switchName }

        # 診斷:把每個參數值與長度印出來,有奇怪字元馬上看得到
        W-Step "建立 VM: $vmName"
        W-Info "  Name      = '$($newVMArgs.Name)' (len=$($newVMArgs.Name.Length))"
        W-Info "  Path      = '$($newVMArgs.Path)' (len=$($newVMArgs.Path.Length))"
        W-Info "  VHDPath   = '$($newVMArgs.VHDPath)' (len=$($newVMArgs.VHDPath.Length))"
        if ($newVMArgs.SwitchName) {
            W-Info "  Switch    = '$($newVMArgs.SwitchName)' (len=$($newVMArgs.SwitchName.Length))"
        }
        W-Info "  Memory    = $($newVMArgs.MemoryStartupBytes) bytes ($memGB GB)"
        W-Info "  Generation= $($newVMArgs.Generation)"

        $createdOK = $false
        $lastErr = $null
        try {
            $null = New-VM @newVMArgs
            $createdOK = $true
            W-OK 'New-VM 完成'
        } catch {
            $lastErr = $_
            W-Err "New-VM 失敗 [$($_.Exception.GetType().FullName)]: $($_.Exception.Message)"

            # 路徑相關錯誤 -> 退回 Hyper-V 預設位置重試一次
            $msg = "$($_.Exception.Message)"
            $isPathErr = ($msg -match '路[徑径]' -or $msg -match 'path' -or $_.Exception -is [System.ArgumentException])
            if ($isPathErr -and $vmPath -ne $hyperVDefaultVMPath) {
                W-Warn "嘗試退回 Hyper-V 預設位置重試: $hyperVDefaultVMPath"
                $newVMArgs.Path = $hyperVDefaultVMPath
                try {
                    $null = New-VM @newVMArgs
                    $createdOK = $true
                    W-OK '改用預設路徑後 New-VM 完成'
                } catch {
                    $lastErr = $_
                    W-Err "重試仍失敗: $($_.Exception.Message)"
                }
            }
        }

        if ($createdOK) {
            try {
                Set-VMProcessor -VMName $vmName -Count $cpuCount -ErrorAction Stop
                W-OK "vCPU 設成 $cpuCount"

                Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $DEFAULT_DYNAMIC_MEM -ErrorAction Stop
                W-OK ("動態記憶體 = {0}" -f $DEFAULT_DYNAMIC_MEM)

                if ($DEFAULT_GENERATION -eq 2) {
                    try {
                        $hdd = Get-VMHardDiskDrive -VMName $vmName | Select-Object -First 1
                        if ($hdd) {
                            Set-VMFirmware -VMName $vmName -FirstBootDevice $hdd -ErrorAction Stop
                            W-OK 'Gen2 開機順序設為硬碟優先'
                        }
                    } catch {
                        W-Warn "設定開機順序失敗 (可手動到 Hyper-V 管理員調): $($_.Exception.Message)"
                    }
                }

                $vmCreatedCount++
                W-OK "[$vmCreatedCount] 完成: $vmName"
            } catch {
                W-Err "後續設定失敗: $($_.Exception.Message)"
                W-Info "VM 已建立但部分屬性沒設好,請到 Hyper-V 管理員手動調整或刪除重建。"
            }
        } else {
            # 嘗試把已建到一半的同名 VM 移掉,避免下次衝突 (不會碰到 VHDX)
            $partial = Get-VM -Name $vmName -ErrorAction SilentlyContinue
            if ($partial) {
                W-Info '嘗試移除半成品 VM (不會碰到 VHDX)'
                try { Remove-VM -Name $vmName -Force -ErrorAction Stop; W-OK '半成品已清除' } catch { W-Warn "清除失敗: $($_.Exception.Message)" }
            }
        }
    }

    # ---------- 再來一台? ----------
    Write-Host ''
    $again = Read-WithDefault '要再建一台嗎?(Y/N)' 'N' $PROMPT_TIMEOUT_SEC
    if ($again -notmatch '^[Yy]') { break }
}

Write-Host ''
W-Title '收工'
W-Info "本次共建立 $vmCreatedCount 台 VM"
Write-Host ''
