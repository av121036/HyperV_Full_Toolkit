# =============================================================================
#  VM_FileSync v1.0 - 把主機資料夾同步進 Hyper-V VM(開機/關機都能用)
# =============================================================================
#  關機中的 VM  -> 掛載 VHDX + robocopy(離線路線)
#  開機中的 VM  -> PowerShell Direct(不走網路);Copy-VMFile 為備援
#  另可在 VM 內加 Windows Defender 排除資料夾,避免複製進去的檔案被砍。
#
#  ⚠ 本檔含中文,必須以 UTF-8 with BOM 存檔,否則 PowerShell 5.1 會用 cp950 解析而炸掉。
#  用法範例(請以系統管理員身分執行):
#    .\VM_FileSync_v1.0.ps1 -VMName 4 -Dest 'C:\VMShare' -AddExclusion -DryRun
#    .\VM_FileSync_v1.0.ps1 -VMName 2,3,4 -Dest 'C:\VMShare' -AddExclusion
# =============================================================================

# PositionalBinding=$false:全部參數只能具名。
# 少了這個,漏打一個參數名就會讓路徑字串位移到 -GuestCredential 上,
# PSCredential 型別收到字串會當成帳號並跳出「認證要求」對話框卡住整個流程。
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]   $Source = (Join-Path $env:USERPROFILE 'Desktop\share_folder'),
    [string[]] $VMName,
    [string]   $Dest = 'C:\VMShare',
    [switch]   $AddExclusion,
    [switch]   $Mirror,
    [switch]   $DryRun,
    [switch]   $ListOnly,
    [System.Management.Automation.PSCredential] $GuestCredential
)

$ErrorActionPreference = 'Stop'

# 客體服務介面的 GUID(用 GUID 比對才不會被系統語言影響)
$script:GSI_GUID     = '6C09BB55-D683-4DA0-8931-C9BF705F6480'
# 本次執行「由本工具加上」的主機排除路徑,收尾時只移除這些
$script:HostExclAdded = New-Object System.Collections.Generic.List[string]

# =============================================================================
#  記錄
# =============================================================================
$script:LogSink = $null    # GUI 層可掛上 scriptblock: param($msg,$level)
$script:GuiMode = $false   # GUI 層要設成 $true,長時間動作才會抽送視窗訊息

function Write-L {
    param([string]$Msg, [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERR')][string]$Level = 'INFO')
    if ($script:LogSink) {
        & $script:LogSink $Msg $Level
        return
    }
    $prefix = switch ($Level) {
        'STEP' { '>> ' } 'OK' { '[OK]  ' } 'WARN' { '[警告] ' } 'ERR' { '[錯誤] ' } default { '      ' }
    }
    $color = switch ($Level) {
        'STEP' { 'Cyan' } 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERR' { 'Red' } default { 'Gray' }
    }
    Write-Host ($prefix + $Msg) -ForegroundColor $color
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 呼叫原生 exe 的統一入口。
# PowerShell 5.1 對原生程式做 2>&1 會把 stderr 每一行包成 ErrorRecord,
# 在 $ErrorActionPreference='Stop' 之下就算 exit code 是 0 也會變成終止錯誤。
# 這裡暫時降級成 Continue,只用 exit code 判斷成敗。
function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & $Exe @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
        return [PSCustomObject]@{ Code = $code; Output = $out.Trim() }
    } finally {
        $ErrorActionPreference = $prev
    }
}

# =============================================================================
#  安全檢查:這台 VM 現在能不能離線寫入?
#  回傳物件 { Name State DiskPath Safe BlockReason Warnings }
#  ⚠ 這是資料保護的關鍵。掛錯差異磁碟鏈會讓整條鏈報廢。
# =============================================================================
function Get-VmSyncInfo {
    param([Parameter(Mandatory)][string]$Name)

    $info = [PSCustomObject]@{
        Name        = $Name
        State       = $null
        DiskPath    = $null
        DiskCount   = 0
        VhdType     = $null
        ParentPath  = $null
        Checkpoints = 0
        Route       = $null      # 'offline' | 'online' | $null
        Safe        = $false
        BlockReason = $null
        Warnings    = @()
    }

    try {
        $vm = Get-VM -Name $Name -ErrorAction Stop
    } catch {
        $info.BlockReason = "找不到 VM「$Name」:$($_.Exception.Message)"
        return $info
    }
    $info.State = [string]$vm.State

    # --- 路線判定 ---
    switch ([string]$vm.State) {
        'Off'     { $info.Route = 'offline' }
        'Running' { $info.Route = 'online' }
        'Saved' {
            $info.BlockReason = 'VM 處於「已儲存」狀態:記憶體狀態尚未寫回,離線寫入登錄檔會被開機時的還原蓋掉。請先正常關機(或捨棄儲存狀態)後再試。'
            return $info
        }
        default {
            $info.BlockReason = "VM 狀態為 $($vm.State),既不是關機也不是執行中,本工具不處理。"
            return $info
        }
    }

    # --- 檢查點防呆(只對離線路線致命)---
    $snaps = @(Get-VMSnapshot -VMName $Name -ErrorAction SilentlyContinue)
    $info.Checkpoints = $snaps.Count

    # --- 磁碟 ---
    $disks = @(Get-VMHardDiskDrive -VMName $Name -ErrorAction SilentlyContinue)
    $info.DiskCount = $disks.Count

    if ($info.Route -eq 'offline') {
        if ($disks.Count -eq 0) {
            $info.BlockReason = '這台 VM 沒有掛任何虛擬硬碟。'
            return $info
        }
        if ($disks.Count -gt 1) {
            $info.BlockReason = "這台 VM 有 $($disks.Count) 顆虛擬硬碟,無法自動判斷哪一顆是系統碟。請先手動確認後改用開機路線。"
            return $info
        }

        $info.DiskPath = $disks[0].Path
        try {
            $vhd = Get-VHD -Path $info.DiskPath -ErrorAction Stop
        } catch {
            $info.BlockReason = "讀不到虛擬硬碟資訊($($info.DiskPath)):$($_.Exception.Message)"
            return $info
        }
        $info.VhdType    = [string]$vhd.VhdType
        $info.ParentPath = $vhd.ParentPath

        if ($info.Checkpoints -gt 0) {
            $info.BlockReason = "這台 VM 有 $($info.Checkpoints) 個檢查點。離線寫入差異磁碟鏈可能讓整條鏈報廢,已擋下。請先刪除檢查點(Hyper-V 管理員 > 刪除檢查點)再試。"
            return $info
        }
        if ($info.VhdType -eq 'Differencing') {
            $info.BlockReason = "虛擬硬碟是差異磁碟(父檔:$($info.ParentPath))。寫入差異鏈有毀損風險,已擋下。"
            return $info
        }
        if ($vhd.Attached) {
            $info.BlockReason = '這個 VHDX 目前已被掛載/佔用中(Attached=True)。請先卸載(Dismount-VHD)再試。'
            return $info
        }
    }

    $info.Safe = $true
    return $info
}

# =============================================================================
#  主機端 Defender 排除(掛載後的磁碟機也會被主機即時保護掃描)
# =============================================================================
function Add-HostExclusion {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $cur = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
        if ($cur -contains $Path) {
            Write-L "主機排除已存在,略過:$Path"
            return
        }
        Add-MpPreference -ExclusionPath $Path -ErrorAction Stop
        $script:HostExclAdded.Add($Path) | Out-Null
        Write-L "已加主機 Defender 排除:$Path" 'OK'
    } catch {
        Write-L "加主機排除失敗(複製途中檔案可能被即時保護攔截):$($_.Exception.Message)" 'WARN'
    }
}

function Remove-AddedHostExclusions {
    foreach ($p in @($script:HostExclAdded)) {
        try {
            Remove-MpPreference -ExclusionPath $p -ErrorAction Stop
            Write-L "已移除主機暫時排除:$p"
        } catch {
            Write-L "移除主機暫時排除失敗($p):$($_.Exception.Message)" 'WARN'
        }
    }
    $script:HostExclAdded.Clear()
}

# =============================================================================
#  VM 內 Defender 排除
# =============================================================================

# 關機路線:寫「群組原則」原則檔(Registry.pol)進離線 VHDX。
#
# 為什麼不是直接改 SOFTWARE hive?
#   本機(Win11 26200)的 RegLoadKey 一律回 err=87,reg.exe load 也全滅,而 reg save 正常。
#   檔案放 C:\ 根目錄、Windows\Temp、使用者 Temp 都一樣,權限(SeRestore/SeBackup)也確認
#   enable 成功 —— 是系統層擋掉 hive 載入,不是用法問題。2026-08-04 實測。
#
# Registry.pol 由 VM 內的群組原則用戶端在開機/gpupdate 時套用成登錄檔值,
# 落點正好是 Defender 讀的原則分支,而且該分支不受 VM 內竄改防護影響。
# ⚠ 代價:不是立即生效,要等 VM 下次開機。
#
# 安全紀律:只「附加」條目,絕不覆寫既有內容(VM 可能已有其他本機原則)。
function New-PolEntry {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$ValueName,
        [Parameter(Mandatory)][int]$Type,
        [Parameter(Mandatory)][byte[]]$Data
    )
    # PReg 條目格式:[ Key<NUL> ; ValueName<NUL> ; Type ; Size ; Data ]
    # 中括號、分號本身也是 UTF-16LE 字元(各 2 bytes)。
    $u   = [System.Text.Encoding]::Unicode
    $ms  = New-Object System.IO.MemoryStream
    $bw  = New-Object System.IO.BinaryWriter($ms)
    $nul = [byte[]]@(0, 0)
    try {
        $bw.Write($u.GetBytes('['))
        $bw.Write($u.GetBytes($Key));       $bw.Write($nul)
        $bw.Write($u.GetBytes(';'))
        $bw.Write($u.GetBytes($ValueName)); $bw.Write($nul)
        $bw.Write($u.GetBytes(';'))
        $bw.Write([BitConverter]::GetBytes([int]$Type))
        $bw.Write($u.GetBytes(';'))
        $bw.Write([BitConverter]::GetBytes([int]$Data.Length))
        $bw.Write($u.GetBytes(';'))
        $bw.Write($Data)
        $bw.Write($u.GetBytes(']'))
        $bw.Flush()
        return $ms.ToArray()
    } finally {
        $bw.Dispose(); $ms.Dispose()
    }
}

function Test-BytesContain {
    param([byte[]]$Haystack, [byte[]]$Needle)
    if (-not $Haystack -or $Haystack.Length -lt $Needle.Length) { return $false }
    $last = $Haystack.Length - $Needle.Length
    for ($i = 0; $i -le $last; $i++) {
        $hit = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $hit = $false; break }
        }
        if ($hit) { return $true }
    }
    return $false
}

function Set-GuestExclusionOffline {
    param(
        [Parameter(Mandatory)][string]$SystemDrive,   # 例:'E:'
        [Parameter(Mandatory)][string]$GuestPath      # 例:'C:\VMShare'(VM 內部看到的路徑)
    )

    $gpDir   = Join-Path $SystemDrive 'Windows\System32\GroupPolicy'
    $macDir  = Join-Path $gpDir 'Machine'
    $polFile = Join-Path $macDir 'Registry.pol'
    $gptFile = Join-Path $gpDir 'gpt.ini'

    if (-not (Test-Path (Join-Path $SystemDrive 'Windows\System32'))) {
        Write-L "找不到 $SystemDrive\Windows\System32,略過 VM 內排除設定。" 'WARN'
        return $false
    }

    try {
        if (-not (Test-Path $macDir)) {
            New-Item -Path $macDir -ItemType Directory -Force | Out-Null
            Write-L "已建立 $macDir"
        }

        $entry = New-PolEntry -Key 'Software\Policies\Microsoft\Windows Defender\Exclusions\Paths' `
                              -ValueName $GuestPath -Type 4 -Data ([byte[]]@(0, 0, 0, 0))

        $existing = $null
        if (Test-Path $polFile) {
            $existing = [System.IO.File]::ReadAllBytes($polFile)
            if ($existing.Length -ge 4 -and
                $existing[0] -eq 0x50 -and $existing[1] -eq 0x52 -and
                $existing[2] -eq 0x65 -and $existing[3] -eq 0x67) {
                if (Test-BytesContain -Haystack $existing -Needle $entry) {
                    Write-L "VM 內排除原則已存在,略過:$GuestPath" 'OK'
                    return $true
                }
                # 備份後附加,絕不改動既有位元組
                $bak = "$polFile.bak-$(Get-Date -Format 'yyyyMMddHHmmss')"
                Copy-Item $polFile $bak -Force
                Write-L "既有 Registry.pol 已備份:$bak"
                $out = New-Object byte[] ($existing.Length + $entry.Length)
                [Array]::Copy($existing, 0, $out, 0, $existing.Length)
                [Array]::Copy($entry, 0, $out, $existing.Length, $entry.Length)
            } else {
                Write-L "既有 Registry.pol 沒有 PReg 標頭(可能損毀),不敢動它,略過 VM 內排除設定。" 'ERR'
                return $false
            }
        } else {
            # PReg 標頭 = 'PReg' + 版本 DWORD 1
            $hdr = [byte[]]@(0x50, 0x52, 0x65, 0x67) + [BitConverter]::GetBytes([int]1)
            $out = New-Object byte[] ($hdr.Length + $entry.Length)
            [Array]::Copy($hdr, 0, $out, 0, $hdr.Length)
            [Array]::Copy($entry, 0, $out, $hdr.Length, $entry.Length)
        }

        [System.IO.File]::WriteAllBytes($polFile, $out)

        # 讀回驗證:檔案裡真的有我們那段位元組
        $back = [System.IO.File]::ReadAllBytes($polFile)
        if (-not (Test-BytesContain -Haystack $back -Needle $entry)) {
            Write-L 'Registry.pol 寫入後讀回驗證失敗' 'ERR'
            return $false
        }

        Update-GptIni -GptPath $gptFile
        Write-L "VM 內 Defender 排除已寫入群組原則檔:$GuestPath" 'OK'
        Write-L 'ⓘ 這條排除在 VM「下次開機」時才由群組原則套用生效。' 'WARN'
        return $true

    } catch {
        Write-L "寫入 VM 內排除原則失敗:$($_.Exception.Message)" 'ERR'
        return $false
    }
}

# 群組原則用戶端靠 gpt.ini 的 Version 判斷要不要重新套用;機器端版本在高 16 位元。
function Update-GptIni {
    param([Parameter(Mandatory)][string]$GptPath)

    # 登錄檔 CSE 與系統管理範本工具的 GUID,少了它群組原則不會處理 Registry.pol
    $cse = '[{35378EAC-683F-11D2-A89A-00C04FBBCFA2}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'

    if (-not (Test-Path $GptPath)) {
        $content = "[General]`r`ngPCMachineExtensionNames=$cse`r`nVersion=65536`r`n"
        [System.IO.File]::WriteAllText($GptPath, $content, [System.Text.Encoding]::ASCII)
        Write-L '已建立 gpt.ini(版本 65536)'
        return
    }

    $lines   = @(Get-Content $GptPath -ErrorAction Stop)
    $newVer  = 65536
    $hasVer  = $false
    $hasCse  = $false
    $result  = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*Version\s*=\s*(\d+)') {
            # 機器端版本 +1(高 16 位元 +65536),使用者端維持不動
            $newVer  = [int]$Matches[1] + 65536
            $result += "Version=$newVer"
            $hasVer  = $true
        } elseif ($line -match '^\s*gPCMachineExtensionNames\s*=') {
            $hasCse = $true
            if ($line -notmatch '35378EAC-683F-11D2-A89A-00C04FBBCFA2') {
                $result += ($line.TrimEnd() + $cse)
            } else {
                $result += $line
            }
        } else {
            $result += $line
        }
    }
    if (-not $hasCse) { $result += "gPCMachineExtensionNames=$cse" }
    if (-not $hasVer) { $result += "Version=$newVer" }

    Copy-Item $GptPath "$GptPath.bak-$(Get-Date -Format 'yyyyMMddHHmmss')" -Force
    [System.IO.File]::WriteAllText($GptPath, (($result -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
    Write-L "gpt.ini 版本已更新為 $newVer"
}

# 開機路線:透過 PowerShell Direct 在 VM 內下 Add-MpPreference
function Set-GuestExclusionOnline {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory)][string]$GuestPath
    )
    try {
        $r = Invoke-Command -Session $Session -ArgumentList $GuestPath -ScriptBlock {
            param($p)
            try {
                $cur = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
                if ($cur -contains $p) { return 'exists' }
                Add-MpPreference -ExclusionPath $p -ErrorAction Stop
                return 'added'
            } catch {
                return "fail:$($_.Exception.Message)"
            }
        }
        if ($r -eq 'added')  { Write-L "VM 內 Defender 排除已加入:$GuestPath" 'OK'; return $true }
        if ($r -eq 'exists') { Write-L "VM 內 Defender 排除已存在:$GuestPath" 'OK'; return $true }
        Write-L "VM 內加排除失敗:$r" 'ERR'
        return $false
    } catch {
        Write-L "VM 內加排除失敗:$($_.Exception.Message)" 'ERR'
        return $false
    }
}

# =============================================================================
#  掛載 / 卸載
# =============================================================================
function Mount-VmSystemDisk {
    param([Parameter(Mandatory)][string]$VhdPath)

    Write-L "掛載 VHDX:$VhdPath" 'STEP'
    $disk = Mount-VHD -Path $VhdPath -Passthru -ErrorAction Stop
    Start-Sleep -Seconds 2

    try {
        $d = Get-Disk -Number $disk.DiskNumber -ErrorAction Stop
        if ($d.IsOffline) {
            Set-Disk -Number $disk.DiskNumber -IsOffline $false -ErrorAction Stop
            Start-Sleep -Seconds 1
        }
    } catch {
        Write-L "磁碟上線檢查略過:$($_.Exception.Message)"
    }

    # 系統分割區 = 最大的那個資料分割區
    $parts = @(Get-Partition -DiskNumber $disk.DiskNumber |
        Where-Object { $_.Type -eq 'Basic' -or $_.Type -eq 'IFS' -or $_.Size -gt 10GB } |
        Sort-Object Size -Descending)
    if ($parts.Count -eq 0) { throw '掛載後找不到可用的分割區' }

    $sys = $parts[0]
    if (-not $sys.DriveLetter) {
        Add-PartitionAccessPath -DiskNumber $disk.DiskNumber -PartitionNumber $sys.PartitionNumber -AssignDriveLetter -ErrorAction Stop
        Start-Sleep -Seconds 1
        $sys = Get-Partition -DiskNumber $disk.DiskNumber -PartitionNumber $sys.PartitionNumber
    }
    $drive = "$($sys.DriveLetter):"

    if (-not (Test-Path (Join-Path $drive 'Windows'))) {
        throw "掛載到 $drive,但找不到 $drive\Windows,這顆不是系統碟"
    }
    Write-L "已掛載到 $drive" 'OK'

    try {
        $vol = Get-Volume -DriveLetter $sys.DriveLetter -ErrorAction SilentlyContinue
        if ($vol) {
            Write-L ('VM 系統碟剩餘空間:{0:N1} GB / {1:N1} GB' -f ($vol.SizeRemaining / 1GB), ($vol.Size / 1GB))
        }
    } catch {}

    return $drive
}

function Dismount-VmSystemDisk {
    param([Parameter(Mandatory)][string]$VhdPath)
    Write-L '卸載 VHDX ...' 'STEP'
    for ($i = 1; $i -le 3; $i++) {
        try {
            Dismount-VHD -Path $VhdPath -ErrorAction Stop
            Write-L '卸載完成' 'OK'
            return $true
        } catch {
            if ($i -eq 3) {
                Write-L "卸載失敗(可能被檔案總管或防毒佔用):$($_.Exception.Message)" 'ERR'
                Write-L "請關閉檔案總管後手動執行: Dismount-VHD -Path `"$VhdPath`"" 'INFO'
                return $false
            }
            [gc]::Collect()
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

# =============================================================================
#  robocopy
# =============================================================================
function Invoke-Robocopy {
    param(
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [switch]$UseMirror,
        [string]$Tag = 'sync'
    )

    $logFile = Join-Path $env:TEMP ("vm_filesync_{0}.log" -f ($Tag -replace '[\s\\\/:*?"<>|]', '_'))
    $mode    = '/E'
    if ($UseMirror) { $mode = '/MIR' }

    $rcArgs = '"{0}" "{1}" {2} /R:1 /W:2 /MT:16 /XJ /NFL /NDL /NJH /NJS /NC /NS /NP /LOG:"{3}"' -f $From, $To, $mode, $logFile
    Write-L "robocopy $mode ..." 'STEP'

    $p = Start-Process robocopy.exe -ArgumentList $rcArgs -WindowStyle Hidden -PassThru
    while (-not $p.HasExited) {
        # 只有 GUI 模式才抽送訊息;CLI 模式下 WinForms 組件根本沒載入,碰型別會炸
        if ($script:GuiMode) { [System.Windows.Forms.Application]::DoEvents() }
        Start-Sleep -Milliseconds 300
    }
    $code = $p.ExitCode

    if ($code -lt 8) {
        $tagTxt = switch ($code) {
            0 { '無變更' } 1 { '複製成功' } 2 { '目的有多餘檔(未刪除)' } 3 { '複製成功 + 目的有多餘檔' }
            default { "code=$code" }
        }
        Write-L "複製完成($tagTxt)" 'OK'
        return $true
    }
    Write-L "robocopy 失敗(code=$code),詳見 $logFile" 'ERR'
    return $false
}

# =============================================================================
#  路線 A:VM 關機 -> 掛載 VHDX
# =============================================================================
function Copy-ToOfflineVm {
    param(
        [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$GuestDest,
        [switch]$WantExclusion,
        [switch]$UseMirror,
        [switch]$WhatIfOnly
    )

    # VM 內路徑 -> 掛載後的主機路徑。只支援 C: (掛載的就是系統碟)
    if ($GuestDest -notmatch '^[Cc]:\\') {
        Write-L "關機路線只能寫進 VM 的 C: 磁碟(目前指定 $GuestDest)。若目的在其他磁碟,請改用開機路線。" 'ERR'
        return $false
    }
    $rel = $GuestDest.Substring(2).TrimStart('\')

    if ($WhatIfOnly) {
        Write-L "[乾跑] 會掛載 $($Info.DiskPath),把 $SourcePath 複製到 VM 的 $GuestDest" 'INFO'
        if ($WantExclusion) { Write-L "[乾跑] 會在 VM 內加 Defender 排除:$GuestDest" 'INFO' }
        return $true
    }

    $drive   = $null
    $success = $false
    try {
        $drive    = Mount-VmSystemDisk -VhdPath $Info.DiskPath
        $hostDest = Join-Path $drive $rel

        # 排除一定要在複製之前設好,否則檔案寫入當下就被即時保護吃掉
        Add-HostExclusion -Path $hostDest

        if ($WantExclusion) {
            [void](Set-GuestExclusionOffline -SystemDrive $drive -GuestPath $GuestDest)
        }

        if (-not (Test-Path $hostDest)) {
            New-Item -Path $hostDest -ItemType Directory -Force | Out-Null
            Write-L "已建立目的資料夾:VM 的 $GuestDest" 'OK'
        }

        $success = Invoke-Robocopy -From $SourcePath -To $hostDest -UseMirror:$UseMirror -Tag ("vm{0}" -f $Info.Name)

    } catch {
        Write-L "離線複製失敗:$($_.Exception.Message)" 'ERR'
        $success = $false
    } finally {
        Remove-AddedHostExclusions
        if ($drive) { [void](Dismount-VmSystemDisk -VhdPath $Info.DiskPath) }
    }
    return $success
}

# =============================================================================
#  路線 B-2:VM 開機中、沒有帳密 -> Copy-VMFile
#
#  這條是「免帳密」路線,只需要主機端啟用客體服務介面(本函式會自動啟用)。
#  限制(照實記,不要事後被驚到):
#    * 只能推,不能拉,也不能在 VM 內執行任何東西 → 無法順便設 Defender 排除
#    * 一次一個檔,沒有遞迴 → 本函式自己展開目錄樹
#    * 沒有「同檔跳過」的概念,每次都整包重傳 → 大量資料重複同步請改走 SMB
# =============================================================================
function Copy-ToRunningVmViaVMFile {
    param(
        [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$GuestDest,
        [switch]$WantExclusion
    )

    if (-not (Enable-GuestServiceInterface -Name $Info.Name)) {
        Write-L '客體服務介面啟用失敗,Copy-VMFile 無法使用。' 'ERR'
        return $false
    }

    if ($WantExclusion) {
        Write-L 'Copy-VMFile 無法在 VM 內執行指令,這條路線設不了 Defender 排除。' 'WARN'
        Write-L '排除請擇一:①VM 關機時跑一次本工具(寫群組原則檔)②提供 -GuestCredential 走 PowerShell Direct。' 'INFO'
    }

    $root  = $SourcePath.TrimEnd('\')
    $files = @(Get-ChildItem -Path $root -Recurse -File -ErrorAction SilentlyContinue)
    if ($files.Count -eq 0) {
        Write-L "來源沒有任何檔案:$root" 'WARN'
        return $true
    }

    $bytes = ($files | Measure-Object Length -Sum).Sum
    $sizeTxt = if ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes / 1GB) }
               elseif ($bytes -ge 1MB) { '{0:N1} MB' -f ($bytes / 1MB) }
               else { '{0:N1} KB' -f ($bytes / 1KB) }
    Write-L "要推送 $($files.Count) 個檔案,共 $sizeTxt(VMBus 傳輸,無增量比對)" 'STEP'
    if ($bytes -ge 1GB) {
        Write-L 'ⓘ 資料量偏大且此路線每次都整包重傳。要反覆同步大量檔案,改用 SMB 從 VM 內拉會快很多(見 README)。' 'WARN'
    }

    $ok = 0
    $fail = 0
    $i = 0
    foreach ($f in $files) {
        $i++
        $rel = $f.FullName.Substring($root.Length).TrimStart('\')
        $dst = Join-Path $GuestDest $rel
        try {
            Copy-VMFile -Name $Info.Name -SourcePath $f.FullName -DestinationPath $dst `
                        -CreateFullPath -FileSource Host -Force -ErrorAction Stop
            $ok++
            if ($i % 10 -eq 0 -or $i -eq $files.Count) {
                Write-L "  進度 $i/$($files.Count)(成功 $ok,失敗 $fail)"
            }
        } catch {
            $fail++
            Write-L "  失敗:$rel — $($_.Exception.Message)" 'ERR'
        }
        if ($script:GuiMode) { [System.Windows.Forms.Application]::DoEvents() }
    }

    if ($fail -eq 0) {
        Write-L "Copy-VMFile 完成:$ok 個檔案全部推送成功" 'OK'
        return $true
    }
    Write-L "Copy-VMFile 結束:成功 $ok、失敗 $fail" 'ERR'
    return $false
}

# =============================================================================
#  路線 B-1:VM 開機中、有帳密 -> PowerShell Direct(支援遞迴,也能設 Defender 排除)
# =============================================================================
function Copy-ToRunningVm {
    param(
        [Parameter(Mandatory)]$Info,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$GuestDest,
        [System.Management.Automation.PSCredential]$Cred,
        [switch]$WantExclusion,
        [switch]$WhatIfOnly
    )

    if ($WhatIfOnly) {
        if ($Cred) {
            Write-L "[乾跑] 有帳密 → 用 PowerShell Direct 連進「$($Info.Name)」,把 $SourcePath 複製到 $GuestDest" 'INFO'
            if ($WantExclusion) { Write-L "[乾跑] 會在 VM 內加 Defender 排除:$GuestDest" 'INFO' }
        } else {
            $n = @(Get-ChildItem -Path $SourcePath.TrimEnd('\') -Recurse -File -ErrorAction SilentlyContinue).Count
            Write-L "[乾跑] 無帳密 → 用 Copy-VMFile 逐檔推送 $n 個檔案到「$($Info.Name)」的 $GuestDest" 'INFO'
            if ($WantExclusion) { Write-L '[乾跑] 這條路線設不了 Defender 排除(見說明)' 'WARN' }
        }
        return $true
    }

    # 沒帳密就走 Copy-VMFile:只靠主機端的「客體服務介面」整合服務,不需要 VM 內任何登入資訊。
    # 空密碼帳號的 VM 只能走這條 —— Windows 預設把空密碼限制成「只能從主控台登入」,
    # PowerShell Direct 會直接回「認證無效」。2026-08-04 在 VM 4 實測確認。
    if (-not $Cred) {
        Write-L "「$($Info.Name)」執行中且未提供帳密 → 改走 Copy-VMFile(免帳密)" 'STEP'
        return (Copy-ToRunningVmViaVMFile -Info $Info -SourcePath $SourcePath -GuestDest $GuestDest -WantExclusion:$WantExclusion)
    }

    $sess    = $null
    $success = $false
    try {
        Write-L "以 PowerShell Direct 連線「$($Info.Name)」..." 'STEP'
        $sess = New-PSSession -VMName $Info.Name -Credential $Cred -ErrorAction Stop
        Write-L '連線成功' 'OK'

        if ($WantExclusion) {
            [void](Set-GuestExclusionOnline -Session $sess -GuestPath $GuestDest)
        }

        Invoke-Command -Session $sess -ArgumentList $GuestDest -ScriptBlock {
            param($d)
            if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
        }
        Write-L "目的資料夾就緒:$GuestDest" 'OK'

        Write-L '複製中(VMBus,不走網路)...' 'STEP'
        Copy-Item -Path (Join-Path $SourcePath '*') -Destination $GuestDest -ToSession $sess -Recurse -Force -ErrorAction Stop
        Write-L '複製完成' 'OK'
        $success = $true

    } catch {
        Write-L "PowerShell Direct 失敗:$($_.Exception.Message)" 'ERR'
        Write-L '常見原因:VM 內的 Windows 版本過舊(需 Win10/Server 2016 以上)、帳密錯誤、或 VM 尚未開機完成。' 'INFO'
        $success = $false
    } finally {
        if ($sess) { Remove-PSSession $sess -ErrorAction SilentlyContinue }
    }
    return $success
}

# =============================================================================
#  客體服務介面(Copy-VMFile 備援路線需要,本機 6 台目前全部關閉)
# =============================================================================
function Enable-GuestServiceInterface {
    param([Parameter(Mandatory)][string]$Name)
    try {
        $svc = Get-VMIntegrationService -VMName $Name -ErrorAction Stop |
               Where-Object { $_.Id -match $script:GSI_GUID }
        if (-not $svc) { Write-L "「$Name」找不到客體服務介面項目" 'WARN'; return $false }
        if ($svc.Enabled) { Write-L "「$Name」的客體服務介面已啟用" 'OK'; return $true }
        $svc | Enable-VMIntegrationService -ErrorAction Stop
        Write-L "「$Name」的客體服務介面已啟用" 'OK'
        return $true
    } catch {
        Write-L "啟用客體服務介面失敗($Name):$($_.Exception.Message)" 'ERR'
        return $false
    }
}

# =============================================================================
#  排程主流程
# =============================================================================
function Invoke-VmFileSync {
    param(
        [Parameter(Mandatory)][string[]]$Targets,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$GuestDest,
        [switch]$WantExclusion,
        [switch]$UseMirror,
        [switch]$WhatIfOnly,
        [System.Management.Automation.PSCredential]$Cred
    )

    $results = @()
    foreach ($t in $Targets) {
        Write-L ''
        Write-L ('=' * 60)
        Write-L "VM「$t」" 'STEP'

        $info = Get-VmSyncInfo -Name $t
        if (-not $info.Safe) {
            Write-L $info.BlockReason 'ERR'
            $results += [PSCustomObject]@{ VM = $t; Route = $info.Route; Result = '擋下'; Detail = $info.BlockReason }
            continue
        }
        $routeTxt = '關機掛載'
        if ($info.Route -eq 'online') {
            if ($Cred) { $routeTxt = 'PowerShell Direct' } else { $routeTxt = 'Copy-VMFile(免帳密)' }
        }
        Write-L "狀態:$($info.State) → 走「$routeTxt」路線"

        $ok = $false
        if ($info.Route -eq 'offline') {
            $ok = Copy-ToOfflineVm -Info $info -SourcePath $SourcePath -GuestDest $GuestDest `
                    -WantExclusion:$WantExclusion -UseMirror:$UseMirror -WhatIfOnly:$WhatIfOnly
        } else {
            $ok = Copy-ToRunningVm -Info $info -SourcePath $SourcePath -GuestDest $GuestDest `
                    -Cred $Cred -WantExclusion:$WantExclusion -WhatIfOnly:$WhatIfOnly
        }

        $resTxt = '失敗'
        if ($ok) { $resTxt = '成功' }
        if ($WhatIfOnly) { $resTxt = '乾跑' }
        $results += [PSCustomObject]@{ VM = $t; Route = $info.Route; Result = $resTxt; Detail = '' }
    }
    return $results
}

# =============================================================================
#  進入點(直接執行本檔時)
# =============================================================================
if ($MyInvocation.InvocationName -ne '.') {

    Write-Host ''
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host '  VM_FileSync v1.0 - 主機資料夾 → Hyper-V VM' -ForegroundColor Cyan
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-Elevated)) {
        Write-L '需要系統管理員權限(Hyper-V cmdlet 與 Defender 設定都會被拒)。請以系統管理員身分重新執行。' 'ERR'
        exit 1
    }

    # 盤點模式:只列出各 VM 現況與可否同步
    if ($ListOnly) {
        $all = @(Get-VM | Sort-Object Name)
        foreach ($vm in $all) {
            $i = Get-VmSyncInfo -Name $vm.Name
            $mark = '可同步'
            if (-not $i.Safe) { $mark = '擋下' }
            Write-Host ''
            Write-Host ("VM {0,-4} 狀態={1,-8} 路線={2,-8} {3}" -f $i.Name, $i.State, $i.Route, $mark)
            if ($i.DiskPath)    { Write-Host ("     磁碟: {0} ({1})" -f $i.DiskPath, $i.VhdType) }
            if ($i.Checkpoints) { Write-Host ("     檢查點: {0}" -f $i.Checkpoints) }
            if ($i.BlockReason) { Write-Host ("     原因: {0}" -f $i.BlockReason) -ForegroundColor Yellow }
        }
        Write-Host ''
        exit 0
    }

    if (-not (Test-Path $Source)) {
        Write-L "來源資料夾不存在:$Source" 'ERR'
        exit 1
    }
    if (-not $VMName -or $VMName.Count -eq 0) {
        Write-L '請用 -VMName 指定目標 VM(例:-VMName 4 或 -VMName 2,3,4),或用 -ListOnly 先看現況。' 'ERR'
        exit 1
    }

    Write-L "來源:$Source"
    Write-L "目的(VM 內路徑):$Dest"
    Write-L "目標 VM:$($VMName -join ', ')"
    if ($Mirror)       { Write-L '鏡像模式:目的端多餘的檔案會被刪除!' 'WARN' }
    if ($DryRun)       { Write-L '乾跑模式:不會真的動任何檔案' 'WARN' }
    if ($AddExclusion) { Write-L '會在 VM 內加入 Defender 排除資料夾' }

    $res = Invoke-VmFileSync -Targets $VMName -SourcePath $Source -GuestDest $Dest `
            -WantExclusion:$AddExclusion -UseMirror:$Mirror -WhatIfOnly:$DryRun -Cred $GuestCredential

    Write-Host ''
    Write-Host '=============== 總結 ===============' -ForegroundColor Cyan
    $res | Format-Table -AutoSize | Out-String | Write-Host
    $failed = @($res | Where-Object { $_.Result -eq '失敗' -or $_.Result -eq '擋下' })
    if ($failed.Count -gt 0) { exit 2 }
    exit 0
}
