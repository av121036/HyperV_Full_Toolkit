# =========================================================
#  Game_Share_GUI_v1.0.ps1  -  遊戲複製 + SMB 共享 一體化 GUI
#
#  整合兩個既有工具的功能:
#    分頁 1「遊戲複製到 VM」 = Host_Master v1.7 的 5d 區塊
#      - 自動偵測 NCSOFT 系列 (Program Files (x86)\NC*)
#      - 2026-08-01 新增: Gamania 新楓之谷經典版
#        (C:\Program Files\Gamania\maplestory_classic)
#      - 勾選要搬的遊戲 -> 關 VM -> 掛 VHDX -> robocopy -> 卸載
#    分頁 2「SMB 共享資料夾」 = Host_Share v1.5 全套
#      - 建共享 + NTFS 權限 + 關密碼保護 + 防火牆 + ICMP
#      - 產生 VM 端 VM_Share_Connect / Update_Host_IP bat + README
#
#  參數:
#    -SelfTest   不開視窗,只跑偵測邏輯並印結果 (自動化驗證用)
# =========================================================
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =========================================================
#  可調參數 - 遊戲偵測來源 (要加新遊戲/新位置改這裡)
# =========================================================
$script:GameSearchConfigs = @(
    @{  Root     = 'C:\Program Files (x86)'
        RootKeys = @('NC', 'NCSOFT')
        Patterns = @('Lineage', 'Purple', '天堂', 'Aion', 'Blade', 'Throne', 'BnS') },
    @{  Root     = 'C:\Program Files'
        RootKeys = @('Gamania')
        Patterns = @('maplestory', '新楓之谷') }
)

# =========================================================
#  共用: 偵測遊戲資料夾
#  回傳 [{Vendor, Game, Src, DstRel, Label}]
#  DstRel = 去掉磁碟機代號的相對路徑 (如 Program Files\Gamania\maplestory_classic)
# =========================================================
function Get-GameJobs {
    $jobs = @()
    foreach ($cfg in $script:GameSearchConfigs) {
        if (-not (Test-Path $cfg.Root)) { continue }
        $vendors = Get-ChildItem $cfg.Root -Directory -ErrorAction SilentlyContinue | Where-Object {
            $n = $_.Name
            @($cfg.RootKeys | Where-Object { $n -ieq $_ }).Count -gt 0
        }
        foreach ($vendor in $vendors) {
            $subs = Get-ChildItem $vendor.FullName -Directory -ErrorAction SilentlyContinue
            foreach ($sub in $subs) {
                $hit = $false
                foreach ($p in $cfg.Patterns) {
                    if ($sub.Name -match $p) { $hit = $true; break }
                }
                if (-not $hit) { continue }
                $jobs += [PSCustomObject]@{
                    Vendor = $vendor.Name
                    Game   = $sub.Name
                    Src    = $sub.FullName
                    DstRel = $sub.FullName -replace '^[A-Za-z]:\\', ''
                    Label  = ('[{0}] {1}' -f $vendor.Name, $sub.Name)
                }
            }
        }
    }
    return @($jobs)
}

# =========================================================
#  SelfTest 模式: 只驗證偵測邏輯,不開視窗
# =========================================================
if ($SelfTest) {
    Write-Host '=== SelfTest: 遊戲偵測 ==='
    $jobs = Get-GameJobs
    foreach ($j in $jobs) {
        Write-Host ('  ' + $j.Label)
        Write-Host ('    Src   : ' + $j.Src)
        Write-Host ('    DstRel: ' + $j.DstRel)
    }
    Write-Host ('共偵測到 ' + @($jobs).Count + ' 個遊戲資料夾')
    Write-Host ''
    Write-Host '=== SelfTest: Hyper-V VM 清單 ==='
    try {
        Import-Module Hyper-V -ErrorAction Stop
        $vms = @(Get-VM | Where-Object { $_.Generation -eq 2 } | Sort-Object Name)
        foreach ($v in $vms) { Write-Host ('  ' + $v.Name + ' (' + $v.State + ')') }
        Write-Host ('共 ' + $vms.Count + ' 台 Gen2 VM')
    } catch {
        Write-Host ('  VM 清單失敗 (可能沒有系統管理員權限): ' + $_.Exception.Message)
    }
    Write-Host ''
    Write-Host '=== SelfTest: 主機網卡 ==='
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -ne '127.0.0.1' } |
            Where-Object { $_.PrefixOrigin -eq 'Manual' -or $_.PrefixOrigin -eq 'Dhcp' } |
            Sort-Object InterfaceMetric
        foreach ($ip in $ips) { Write-Host ('  ' + $ip.InterfaceAlias + ' = ' + $ip.IPAddress) }
    } catch { Write-Host ('  失敗: ' + $_.Exception.Message) }
    Write-Host 'SelfTest 偵測部分完成,接著驗證 UI 建構...'
}

# =========================================================
#  GUI 建構
# =========================================================
$uiFont     = New-Object System.Drawing.Font('LXGW WenKai Mono TC', 10)
$uiFontBold = New-Object System.Drawing.Font('LXGW WenKai Mono TC', 10, [System.Drawing.FontStyle]::Bold)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Game + Share 工具 v1.0  (遊戲複製到 VM / SMB 共享)'
$form.Size = New-Object System.Drawing.Size(940, 760)
$form.StartPosition = 'CenterScreen'
$form.Font = $uiFont
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

# ---- 下方共用 log ----
$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location = New-Object System.Drawing.Point(10, 420)
$rtbLog.Size = New-Object System.Drawing.Size(906, 290)
$rtbLog.ReadOnly = $true
$rtbLog.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
$rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
$rtbLog.Font = New-Object System.Drawing.Font('LXGW WenKai Mono TC', 9)
$form.Controls.Add($rtbLog)

function Log($msg, $color) {
    if (-not $color) { $color = [System.Drawing.Color]::Gainsboro }
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.SelectionColor = $color
    $rtbLog.AppendText($msg + "`r`n")
    $rtbLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}
function Log-Step($m) { Log ('[*] ' + $m) ([System.Drawing.Color]::Khaki) }
function Log-OK($m)   { Log ('[+] ' + $m) ([System.Drawing.Color]::LightGreen) }
function Log-Err($m)  { Log ('[X] ' + $m) ([System.Drawing.Color]::Salmon) }
function Log-Info($m) { Log ('    ' + $m) ([System.Drawing.Color]::Gray) }

# ---- TabControl ----
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 10)
$tabs.Size = New-Object System.Drawing.Size(906, 400)
$form.Controls.Add($tabs)

$tabCopy  = New-Object System.Windows.Forms.TabPage
$tabCopy.Text = ' 遊戲複製到 VM '
$tabShare = New-Object System.Windows.Forms.TabPage
$tabShare.Text = ' SMB 共享資料夾 '
$tabs.TabPages.Add($tabCopy)
$tabs.TabPages.Add($tabShare)

# =========================================================
#  分頁 1: 遊戲複製到 VM
# =========================================================
$lblVM = New-Object System.Windows.Forms.Label
$lblVM.Text = '目標 VM (Gen2):'
$lblVM.Location = New-Object System.Drawing.Point(15, 18)
$lblVM.AutoSize = $true
$tabCopy.Controls.Add($lblVM)

$cboVM = New-Object System.Windows.Forms.ComboBox
$cboVM.Location = New-Object System.Drawing.Point(150, 14)
$cboVM.Size = New-Object System.Drawing.Size(280, 28)
$cboVM.DropDownStyle = 'DropDownList'
$tabCopy.Controls.Add($cboVM)

$btnVMRefresh = New-Object System.Windows.Forms.Button
$btnVMRefresh.Text = '重新整理 VM'
$btnVMRefresh.Location = New-Object System.Drawing.Point(445, 12)
$btnVMRefresh.Size = New-Object System.Drawing.Size(130, 30)
$tabCopy.Controls.Add($btnVMRefresh)

$lblGames = New-Object System.Windows.Forms.Label
$lblGames.Text = '偵測到的遊戲資料夾 (勾選要複製的;來源含 NCSOFT 與 Gamania 新楓之谷):'
$lblGames.Location = New-Object System.Drawing.Point(15, 55)
$lblGames.AutoSize = $true
$tabCopy.Controls.Add($lblGames)

$clbGames = New-Object System.Windows.Forms.CheckedListBox
$clbGames.Location = New-Object System.Drawing.Point(15, 80)
$clbGames.Size = New-Object System.Drawing.Size(700, 220)
$clbGames.CheckOnClick = $true
$clbGames.HorizontalScrollbar = $true
$tabCopy.Controls.Add($clbGames)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = '重新掃描'
$btnScan.Location = New-Object System.Drawing.Point(730, 80)
$btnScan.Size = New-Object System.Drawing.Size(150, 34)
$tabCopy.Controls.Add($btnScan)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = '開始複製到 VM'
$btnCopy.Location = New-Object System.Drawing.Point(730, 130)
$btnCopy.Size = New-Object System.Drawing.Size(150, 46)
$btnCopy.Font = $uiFontBold
$btnCopy.BackColor = [System.Drawing.Color]::FromArgb(255, 180, 90)
$tabCopy.Controls.Add($btnCopy)

$lblCopyNote = New-Object System.Windows.Forms.Label
$lblCopyNote.Text = "說明:複製需要 VM 關機 (執行中會先詢問是否關機),`n流程 = 掛載 VHDX -> robocopy 16 執行緒 -> 卸載。`n大型遊戲可能要跑很久,期間不要關這個視窗。"
$lblCopyNote.Location = New-Object System.Drawing.Point(15, 310)
$lblCopyNote.Size = New-Object System.Drawing.Size(860, 60)
$lblCopyNote.ForeColor = [System.Drawing.Color]::DimGray
$tabCopy.Controls.Add($lblCopyNote)

$script:GameJobs = @()

function Refresh-VMList {
    $cboVM.Items.Clear()
    try {
        Import-Module Hyper-V -ErrorAction Stop
        $vms = @(Get-VM | Where-Object { $_.Generation -eq 2 } | Sort-Object Name)
        foreach ($v in $vms) {
            [void]$cboVM.Items.Add(('{0}  ({1})' -f $v.Name, $v.State))
        }
        if ($cboVM.Items.Count -gt 0) { $cboVM.SelectedIndex = 0 }
        Log-OK ('VM 清單已更新: ' + $vms.Count + ' 台 Gen2 VM')
    } catch {
        Log-Err ('讀取 VM 清單失敗: ' + $_.Exception.Message)
        Log-Info '請確認是用「以系統管理員身分執行」開啟本工具'
    }
}

function Refresh-GameList {
    $clbGames.Items.Clear()
    $script:GameJobs = Get-GameJobs
    foreach ($j in $script:GameJobs) {
        [void]$clbGames.Items.Add($j.Label, $false)
    }
    Log-OK ('遊戲掃描完成: 偵測到 ' + @($script:GameJobs).Count + ' 個')
    foreach ($j in $script:GameJobs) { Log-Info ($j.Label + '  <- ' + $j.Src) }
    if (@($script:GameJobs).Count -eq 0) {
        Log-Info '找不到遊戲?請確認安裝位置,或編輯本檔最上方 $GameSearchConfigs'
    }
}

function Get-SelectedVMName {
    if ($cboVM.SelectedIndex -lt 0) { return $null }
    # 顯示字串格式 "Name  (State)",取回名稱
    $txt = [string]$cboVM.SelectedItem
    return ($txt -replace '\s+\([^)]*\)\s*$', '')
}

$btnVMRefresh.Add_Click({ Refresh-VMList })
$btnScan.Add_Click({ Refresh-GameList })

$btnCopy.Add_Click({
    $btnCopy.Enabled = $false
    try {
        $vmName = Get-SelectedVMName
        if (-not $vmName) { Log-Err '請先選擇目標 VM'; return }

        $selIdx = @($clbGames.CheckedIndices)
        if ($selIdx.Count -eq 0) { Log-Err '請先勾選至少一個遊戲'; return }
        $sel = @($selIdx | ForEach-Object { $script:GameJobs[$_] })

        Log ''
        Log-Step ('目標 VM: ' + $vmName + ' | 要複製 ' + $sel.Count + ' 個遊戲')

        # --- VM 必須關機 ---
        $vm = Get-VM -Name $vmName -ErrorAction Stop
        if ($vm.State -ne 'Off') {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                ('VM「' + $vmName + '」目前是 ' + $vm.State + ' 狀態,複製需要關機。' + "`n`n要立即強制關機嗎?"),
                '需要關機', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { Log-Err '已取消 (VM 未關機)'; return }
            Log-Step ('關閉 ' + $vmName + ' ...')
            Stop-VM -Name $vmName -Force -ErrorAction Stop
            Log-OK '已關機'
        }

        # --- 掛載 VHDX ---
        $hdd = Get-VMHardDiskDrive -VMName $vmName | Select-Object -First 1
        if (-not $hdd) { Log-Err '這個 VM 沒有掛 VHDX'; return }
        $vhdPath = $hdd.Path
        Log-Info ('VHDX: ' + $vhdPath)

        $mounted = $false
        $vmDrive = $null
        try {
            Log-Step '掛載 VHDX ...'
            $disk = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
            $mounted = $true
            Start-Sleep -Seconds 2
            $parts = @(Get-Partition -DiskNumber $disk.DiskNumber |
                Where-Object { $_.Type -eq 'Basic' -or $_.Type -eq 'IFS' -or $_.Size -gt 10GB } |
                Sort-Object Size -Descending)
            if ($parts.Count -eq 0) { throw '找不到可掛載的分區' }
            $sysPart = $parts[0]
            if (-not $sysPart.DriveLetter) {
                Add-PartitionAccessPath -DiskNumber $disk.DiskNumber -PartitionNumber $sysPart.PartitionNumber -AssignDriveLetter
                Start-Sleep -Seconds 1
                $sysPart = Get-Partition -DiskNumber $disk.DiskNumber -PartitionNumber $sysPart.PartitionNumber
            }
            $vmDrive = $sysPart.DriveLetter + ':'
            Log-OK ('已掛載到 ' + $vmDrive)
            if (-not (Test-Path (Join-Path $vmDrive 'Windows'))) {
                throw ('找不到 ' + $vmDrive + '\Windows,這個 VHDX 可能不是系統碟')
            }

            try {
                $vol = Get-Volume -DriveLetter $sysPart.DriveLetter -ErrorAction SilentlyContinue
                if ($vol) {
                    Log-Info ('VM 系統碟剩餘空間: {0:N1} GB / {1:N1} GB' -f ($vol.SizeRemaining / 1GB), ($vol.Size / 1GB))
                }
            } catch {}

            # --- 逐一 robocopy ---
            $jobIdx = 0
            $okCount = 0
            foreach ($j in $sel) {
                $jobIdx++
                $dst = Join-Path $vmDrive $j.DstRel
                Log-Step ('[{0}/{1}] {2}' -f $jobIdx, $sel.Count, $j.Label)
                Log-Info ('  來源: ' + $j.Src)
                Log-Info ('  目的: ' + $dst)

                $dstParent = Split-Path $dst -Parent
                if (-not (Test-Path $dstParent)) {
                    New-Item -Path $dstParent -ItemType Directory -Force | Out-Null
                }

                $logSuffix = (($j.Vendor + '_' + $j.Game) -replace '[\s\\\/:*?"<>|]', '_')
                $rcLog = Join-Path $env:TEMP ('robocopy_gui_' + $logSuffix + '.log')
                $rcArgs = ('"{0}" "{1}" /E /R:1 /W:2 /MT:16 /XJ /NFL /NDL /NJH /NJS /NC /NS /NP /LOG:"{2}"' -f $j.Src, $dst, $rcLog)

                $p = Start-Process robocopy.exe -ArgumentList $rcArgs -WindowStyle Hidden -PassThru
                while (-not $p.HasExited) {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 300
                }
                $rcExit = $p.ExitCode
                if ($rcExit -lt 8) {
                    $tag = switch ($rcExit) {
                        0 { '無變更' } 1 { '複製成功' } 2 { '目的有多餘檔(已忽略)' } 3 { '複製成功+目的有多餘檔' }
                        default { ('code=' + $rcExit) }
                    }
                    Log-OK ('  ' + $j.Game + ' 完成 (' + $tag + ')')
                    $okCount++
                } else {
                    Log-Err ('  ' + $j.Game + ' 複製失敗 (robocopy code=' + $rcExit + '),log: ' + $rcLog)
                }
            }
            Log-OK ('複製完成: 成功 ' + $okCount + ' / ' + $sel.Count + ' 個')
        } finally {
            if ($mounted) {
                Log-Step '卸載 VHDX ...'
                try {
                    Dismount-VHD -Path $vhdPath -ErrorAction Stop
                    Log-OK '卸載完成'
                } catch {
                    Log-Err ('卸載失敗(可能被佔用): ' + $_.Exception.Message)
                    Log-Info ('請關閉檔案總管後手動執行: Dismount-VHD -Path "' + $vhdPath + '"')
                }
            }
        }
        Log-Info '提示: 首次執行遊戲可能需要在 VM 內補裝 VC++ Redist / DirectX'
    } catch {
        Log-Err ('複製流程失敗: ' + $_.Exception.Message)
    } finally {
        $btnCopy.Enabled = $true
    }
})

# =========================================================
#  分頁 2: SMB 共享資料夾 (Host_Share v1.5 邏輯移植)
# =========================================================
$lblHost = New-Object System.Windows.Forms.Label
$lblHost.Text = ('主機名稱: ' + $env:COMPUTERNAME + '   (VM 優先用名稱連線,不怕 IP 變)')
$lblHost.Location = New-Object System.Drawing.Point(15, 18)
$lblHost.AutoSize = $true
$tabShare.Controls.Add($lblHost)

$lblIP = New-Object System.Windows.Forms.Label
$lblIP.Text = '備援 IP:'
$lblIP.Location = New-Object System.Drawing.Point(15, 52)
$lblIP.AutoSize = $true
$tabShare.Controls.Add($lblIP)

$cboIP = New-Object System.Windows.Forms.ComboBox
$cboIP.Location = New-Object System.Drawing.Point(150, 48)
$cboIP.Size = New-Object System.Drawing.Size(460, 28)
$cboIP.DropDownStyle = 'DropDownList'
$tabShare.Controls.Add($cboIP)

$btnIPRefresh = New-Object System.Windows.Forms.Button
$btnIPRefresh.Text = '重新整理'
$btnIPRefresh.Location = New-Object System.Drawing.Point(625, 46)
$btnIPRefresh.Size = New-Object System.Drawing.Size(110, 30)
$tabShare.Controls.Add($btnIPRefresh)

$lblPath = New-Object System.Windows.Forms.Label
$lblPath.Text = '共享資料夾:'
$lblPath.Location = New-Object System.Drawing.Point(15, 90)
$lblPath.AutoSize = $true
$tabShare.Controls.Add($lblPath)

$txtSharePath = New-Object System.Windows.Forms.TextBox
$txtSharePath.Location = New-Object System.Drawing.Point(150, 86)
$txtSharePath.Size = New-Object System.Drawing.Size(460, 28)
$txtSharePath.Text = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'share_folder')
$tabShare.Controls.Add($txtSharePath)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '瀏覽...'
$btnBrowse.Location = New-Object System.Drawing.Point(625, 84)
$btnBrowse.Size = New-Object System.Drawing.Size(110, 30)
$tabShare.Controls.Add($btnBrowse)

$lblShareName = New-Object System.Windows.Forms.Label
$lblShareName.Text = '共享名稱:'
$lblShareName.Location = New-Object System.Drawing.Point(15, 128)
$lblShareName.AutoSize = $true
$tabShare.Controls.Add($lblShareName)

$txtShareName = New-Object System.Windows.Forms.TextBox
$txtShareName.Location = New-Object System.Drawing.Point(150, 124)
$txtShareName.Size = New-Object System.Drawing.Size(220, 28)
$txtShareName.Text = 'share_folder'
$tabShare.Controls.Add($txtShareName)

$grpPerm = New-Object System.Windows.Forms.GroupBox
$grpPerm.Text = '權限模式'
$grpPerm.Location = New-Object System.Drawing.Point(15, 162)
$grpPerm.Size = New-Object System.Drawing.Size(400, 60)
$tabShare.Controls.Add($grpPerm)

$rdoRW = New-Object System.Windows.Forms.RadioButton
$rdoRW.Text = '讀寫 (雙向檔案交換)'
$rdoRW.Location = New-Object System.Drawing.Point(15, 24)
$rdoRW.AutoSize = $true
$rdoRW.Checked = $true
$grpPerm.Controls.Add($rdoRW)

$rdoRO = New-Object System.Windows.Forms.RadioButton
$rdoRO.Text = '唯讀 (安裝檔分發)'
$rdoRO.Location = New-Object System.Drawing.Point(210, 24)
$rdoRO.AutoSize = $true
$grpPerm.Controls.Add($rdoRO)

$btnShare = New-Object System.Windows.Forms.Button
$btnShare.Text = '建立 SMB 共享'
$btnShare.Location = New-Object System.Drawing.Point(15, 240)
$btnShare.Size = New-Object System.Drawing.Size(180, 46)
$btnShare.Font = $uiFontBold
$btnShare.BackColor = [System.Drawing.Color]::FromArgb(140, 200, 255)
$tabShare.Controls.Add($btnShare)

$btnOpenShare = New-Object System.Windows.Forms.Button
$btnOpenShare.Text = '開啟共享資料夾'
$btnOpenShare.Location = New-Object System.Drawing.Point(215, 240)
$btnOpenShare.Size = New-Object System.Drawing.Size(180, 46)
$tabShare.Controls.Add($btnOpenShare)

$lblShareNote = New-Object System.Windows.Forms.Label
$lblShareNote.Text = "建立完成後,把共享資料夾裡的 VM_Share_Connect_v1.5.bat 複製到 VM 桌面,`n在 VM 內以系統管理員身分執行;第一次跑完要重開 VM 一次 (UAC 設定重開才生效)。"
$lblShareNote.Location = New-Object System.Drawing.Point(15, 300)
$lblShareNote.Size = New-Object System.Drawing.Size(860, 50)
$lblShareNote.ForeColor = [System.Drawing.Color]::DimGray
$tabShare.Controls.Add($lblShareNote)

function Refresh-IPList {
    $cboIP.Items.Clear()
    try {
        $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -ne '127.0.0.1' } |
            Where-Object { $_.PrefixOrigin -eq 'Manual' -or $_.PrefixOrigin -eq 'Dhcp' } |
            Sort-Object InterfaceMetric
        $preferIdx = -1
        $i = 0
        foreach ($ip in $ips) {
            $tag = ''
            if ($ip.InterfaceAlias -match 'vEthernet|Hyper-V|Default Switch') { $tag = '   << VM 用這條'; if ($preferIdx -lt 0) { $preferIdx = $i } }
            [void]$cboIP.Items.Add(('{0}  ({1}){2}' -f $ip.IPAddress, $ip.InterfaceAlias, $tag))
            $i++
        }
        if ($cboIP.Items.Count -gt 0) {
            $cboIP.SelectedIndex = $(if ($preferIdx -ge 0) { $preferIdx } else { 0 })
        }
        Log-OK ('網卡清單已更新: ' + $cboIP.Items.Count + ' 條')
    } catch {
        Log-Err ('讀取網卡失敗: ' + $_.Exception.Message)
    }
}

$btnIPRefresh.Add_Click({ Refresh-IPList })

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '選擇共享資料夾 (不存在會自動建立)'
    if (Test-Path $txtSharePath.Text) { $dlg.SelectedPath = $txtSharePath.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $txtSharePath.Text = $dlg.SelectedPath }
})

$btnOpenShare.Add_Click({
    if (Test-Path $txtSharePath.Text) { Start-Process explorer.exe -ArgumentList $txtSharePath.Text }
    else { Log-Err ('資料夾不存在: ' + $txtSharePath.Text) }
})

$btnShare.Add_Click({
    $btnShare.Enabled = $false
    try {
        $hostName = $env:COMPUTERNAME
        if ($cboIP.SelectedIndex -lt 0) { Log-Err '請先選擇備援 IP'; return }
        $hostIp = ([string]$cboIP.SelectedItem -split '\s+')[0]
        $sharePath = $txtSharePath.Text.Trim()
        $shareName = $txtShareName.Text.Trim()
        if (-not $sharePath) { Log-Err '共享路徑不能是空的'; return }
        if (-not $shareName -or $shareName -match '[\\\/:*?"<>|\s]') { Log-Err '共享名稱不合法 (不能有空白或 \ / : * ? " < > |)'; return }

        Log ''
        Log-Step ('建立 SMB 共享: \\{0}\{1}  (備援 \\{2}\{1})' -f $hostName, $shareName, $hostIp)

        # 1. 資料夾
        if (-not (Test-Path $sharePath)) {
            New-Item -Path $sharePath -ItemType Directory -Force | Out-Null
            Log-OK ('已建立資料夾: ' + $sharePath)
        }

        # 2. NTFS 權限
        Log-Step 'NTFS 權限 (Everyone 可讀寫)'
        try {
            $null = icacls $sharePath /grant "Everyone:(OI)(CI)M" /T 2>&1
            Log-OK 'NTFS 權限設定完成'
        } catch { Log-Err ('NTFS 權限失敗: ' + $_.Exception.Message) }

        # 3. SMB 共享
        $shareAccess = if ($rdoRO.Checked) { 'Read' } else { 'Change' }
        $modeName    = if ($rdoRO.Checked) { '唯讀' } else { '讀寫' }
        Log-Step ('建立共享 (' + $modeName + ')')
        Get-SmbShare -Name $shareName -ErrorAction SilentlyContinue | Remove-SmbShare -Force -ErrorAction SilentlyContinue
        if ($shareAccess -eq 'Read') {
            New-SmbShare -Name $shareName -Path $sharePath -ReadAccess 'Everyone' -Description 'VM Shared Folder (RO)' | Out-Null
        } else {
            New-SmbShare -Name $shareName -Path $sharePath -ChangeAccess 'Everyone' -Description 'VM Shared Folder (RW)' | Out-Null
        }
        Log-OK 'SMB 共享建立成功'

        # 4. 關密碼保護共享
        Log-Step '關閉密碼保護共享 (登錄檔)'
        try {
            New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
                -Name 'EveryoneIncludesAnonymous' -Value 1 -PropertyType DWord -Force | Out-Null
            New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' `
                -Name 'RestrictNullSessAccess' -Value 0 -PropertyType DWord -Force | Out-Null
            Log-OK '登錄檔已設定'
        } catch { Log-Err ('登錄檔失敗: ' + $_.Exception.Message) }

        Log-Step '重啟 SMB Server 服務'
        try {
            Restart-Service LanmanServer -Force -ErrorAction Stop
            Log-OK 'LanmanServer 已重啟'
        } catch { Log-Err ('重啟失敗: ' + $_.Exception.Message) }

        # 5. 防火牆
        Log-Step '防火牆放行 檔案及印表機共用 + ICMP'
        try {
            Get-NetFirewallRule -DisplayGroup '檔案及印表機共用' -ErrorAction SilentlyContinue |
                Set-NetFirewallRule -Enabled True -Profile Any -ErrorAction SilentlyContinue
            Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue |
                Set-NetFirewallRule -Enabled True -Profile Any -ErrorAction SilentlyContinue
            netsh advfirewall firewall add rule name="ICMP Allow incoming V4" protocol=icmpv4:8,any dir=in action=allow 2>&1 | Out-Null
            Log-OK '防火牆規則已啟用'
        } catch { Log-Err ('防火牆失敗: ' + $_.Exception.Message) }

        # 6. 產生 VM 端 bat + README (內容與 Host_Share v1.5 相同)
        Log-Step '產生 VM 端 VM_Share_Connect_v1.5.bat / Update_Host_IP_v1.5.bat / README.txt'

        $vmConnectBat = @"
@echo off
REM ============================================================
REM  VM_Share_Connect_v1.5.bat (auto-generated by Game_Share_GUI_v1.0)
REM  Run this INSIDE VM as Administrator
REM
REM  Connect order:
REM    1. host name (IP-change proof)
REM    2. backup IP recorded at build time
REM    3. auto-detect current host IP via ping
REM
REM  Auto-fixes:
REM    - AllowInsecureGuestAuth    (SMB guest login block)
REM    - EnableLinkedConnections   (UAC admin/user token split)
REM    - Clears stuck Z: mappings
REM ============================================================
title VM Share Auto-Connect v1.5
color 0B

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Please right-click and Run as Administrator
    echo.
    pause
    exit /b 1
)

set "HOST_NAME=$hostName"
set "HOST_IP_BACKUP=$hostIp"
set "SHARE_NAME=$shareName"

echo.
echo ============================================================
echo  VM to Host Share Auto-Connect v1.5
echo  Host name : %HOST_NAME%   (preferred, IP-change proof)
echo  Backup IP : %HOST_IP_BACKUP%
echo  Share     : %SHARE_NAME%
echo ============================================================
echo.

echo [1/7] Enable SMB guest auth (AllowInsecureGuestAuth)...
reg add "HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" /v AllowInsecureGuestAuth /t REG_DWORD /d 1 /f >nul

echo [2/7] Enable UAC linked connections (EnableLinkedConnections)...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v EnableLinkedConnections /t REG_DWORD /d 1 /f >nul

echo [3/7] Clear any stuck Z: and Y: mappings...
net use Z: /delete /y >nul 2>&1
net use Y: /delete /y >nul 2>&1

echo [4/7] Restart LanmanWorkstation service...
net stop LanmanWorkstation /y >nul 2>&1
net start LanmanWorkstation >nul 2>&1

echo [5/7] Try connecting via host name: \\%HOST_NAME%\%SHARE_NAME% ...
net use Z: \\%HOST_NAME%\%SHARE_NAME% /PERSISTENT:YES >nul 2>&1
if not errorlevel 1 (
    echo     [+] Connected via host name
    goto CONN_OK
)

echo     [!] Name resolution failed, trying backup IP...
echo.
echo [6/7] Try connecting via backup IP: \\%HOST_IP_BACKUP%\%SHARE_NAME% ...
net use Z: \\%HOST_IP_BACKUP%\%SHARE_NAME% /PERSISTENT:YES >nul 2>&1
if not errorlevel 1 (
    echo     [+] Connected via backup IP
    echo     [!] WARN: Host name failed - consider running Update_Host_IP_v1.5.bat
    echo              if host IP has changed permanently
    goto CONN_OK
)

echo     [!] Backup IP also failed, trying to auto-detect host IP...
echo.
echo [7/7] Auto-detect host IP via ping %HOST_NAME% ...
set "DETECTED_IP="
for /f "tokens=2 delims=[]" %%a in ('ping -n 1 -4 %HOST_NAME% 2^>nul ^| findstr /C:"["') do set "DETECTED_IP=%%a"
if defined DETECTED_IP (
    echo     Detected host IP: %DETECTED_IP%
    net use Z: \\%DETECTED_IP%\%SHARE_NAME% /PERSISTENT:YES >nul 2>&1
    if not errorlevel 1 (
        echo     [+] Connected via auto-detected IP
        goto CONN_OK
    )
)

goto CONN_FAILED

:CONN_OK
echo.
echo ============================================================
echo [+] Connected successfully
echo [+] Z: -^> Host share %SHARE_NAME%
echo ============================================================
echo.
echo If File Explorer does NOT show Z: drive:
echo   -^> First-time EnableLinkedConnections setup
echo   -^> Please REBOOT the VM once, then it will show up
echo.
start explorer Z:\
pause
exit /b 0

:CONN_FAILED
echo.
echo ============================================================
echo [X] All connection attempts failed. Diagnosis:
echo ============================================================
echo.
echo  1. Can VM reach host?
echo        ping %HOST_NAME%
echo        ping %HOST_IP_BACKUP%
echo.
echo  2. If host IP has permanently changed:
echo        Run Update_Host_IP_v1.5.bat (in this folder)
echo        and enter the new IP
echo.
echo  3. Check on host side:
echo        - SMB share exists?  (PowerShell: Get-SmbShare)
echo        - Firewall blocking? (File and Printer Sharing rule)
echo.
echo  4. Verify share visible from VM:
echo        net view \\%HOST_NAME%
echo        net view \\%HOST_IP_BACKUP%
echo.
pause
exit /b 1
"@
        Set-Content -Path (Join-Path $sharePath 'VM_Share_Connect_v1.5.bat') -Value $vmConnectBat -Encoding ASCII

        $updateIpBat = @"
@echo off
REM ============================================================
REM  Update_Host_IP_v1.5.bat (auto-generated by Game_Share_GUI_v1.0)
REM  Run INSIDE VM as Administrator
REM  Use when: host IP changed AND name resolution doesn't work
REM
REM  This script writes the new host IP into VM's hosts file,
REM  so \\$hostName\$shareName will resolve correctly again.
REM ============================================================
title Update Host IP Mapping v1.5
color 0E

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo [X] Please right-click and Run as Administrator
    pause
    exit /b 1
)

set "HOST_NAME=$hostName"
set "SHARE_NAME=$shareName"
set "HOSTS_FILE=%SystemRoot%\System32\drivers\etc\hosts"

echo.
echo ============================================================
echo  Update host IP mapping for: %HOST_NAME%
echo ============================================================
echo.
echo  This will edit VM's hosts file:
echo    %HOSTS_FILE%
echo.

set /p NEW_IP="Enter new host IP (e.g. 192.168.1.50): "
if "%NEW_IP%"=="" (
    echo [X] No IP entered, abort.
    pause
    exit /b 1
)

echo.
echo [1/3] Backup current hosts file...
copy /Y "%HOSTS_FILE%" "%HOSTS_FILE%.bak" >nul

echo [2/3] Remove old %HOST_NAME% entries...
findstr /v /i /c:"%HOST_NAME%" "%HOSTS_FILE%" > "%TEMP%\hosts.new"
copy /Y "%TEMP%\hosts.new" "%HOSTS_FILE%" >nul
del "%TEMP%\hosts.new" >nul 2>&1

echo [3/3] Add new mapping: %NEW_IP%  %HOST_NAME%
echo %NEW_IP%    %HOST_NAME%>> "%HOSTS_FILE%"

echo.
echo Flushing DNS cache...
ipconfig /flushdns >nul

echo.
echo ============================================================
echo [+] Done! Now testing...
echo ============================================================
ping -n 1 %HOST_NAME%
echo.
echo Now try running VM_Share_Connect_v1.5.bat again.
echo.
pause
exit /b 0
"@
        Set-Content -Path (Join-Path $sharePath 'Update_Host_IP_v1.5.bat') -Value $updateIpBat -Encoding ASCII

        $readme = @"
# VM 共享資料夾說明 (Game_Share_GUI_v1.0 產生,內容同 Host_Share v1.5)

## 主機端(已建置完成)
- 共享路徑   : $sharePath
- 主機名稱   : $hostName              <-- VM 優先用這個連
- 共享網址   : \\$hostName\$shareName  (推薦)
- 備援網址   : \\$hostIp\$shareName    (主機 IP 變動就會失效)
- 權限模式   : $modeName
- NTFS 權限  : Everyone V
- 密碼保護   : 已關閉 V

## VM 端使用方式
1. 開啟 VM
2. VM 檔案總管進入 \\$hostName\$shareName  (或 \\$hostIp\$shareName)
3. 把 VM_Share_Connect_v1.5.bat 複製到 VM 桌面
4. 右鍵「以系統管理員身分執行」
5. 第一次執行後,**重開 VM 一次**讓 EnableLinkedConnections 生效
6. 重開後就會在檔案總管看到 Z: 槽

## 萬一主機名稱解析不到
VM 端用系統管理員身份執行 Update_Host_IP_v1.5.bat,輸入主機當下 IP
(主機端打 ipconfig 查),它會寫進 VM 的 hosts 檔;之後 IP 再變重跑一次即可。

## 移除共享(主機端以系統管理員 PowerShell)
    Remove-SmbShare -Name $shareName -Force
"@
        Set-Content -Path (Join-Path $sharePath 'README.txt') -Value $readme -Encoding UTF8

        Log-OK ('VM 端檔案已寫入: ' + $sharePath)
        Log ''
        Log-OK ('共享建立完成! 推薦網址 \\{0}\{1}  備援 \\{2}\{1}' -f $hostName, $shareName, $hostIp)
        Log-Info '下一步: 把共享資料夾裡的 VM_Share_Connect_v1.5.bat 拿到 VM 內以系統管理員執行,'
        Log-Info '        第一次跑完重開 VM 一次,之後檔案總管就有 Z: 槽。'
    } catch {
        Log-Err ('共享建立失敗: ' + $_.Exception.Message)
    } finally {
        $btnShare.Enabled = $true
    }
})

# =========================================================
#  啟動
# =========================================================
$form.Add_Shown({
    Log ('Game + Share 工具 v1.0  |  主機: ' + $env:COMPUTERNAME) ([System.Drawing.Color]::LightSkyBlue)
    Refresh-VMList
    Refresh-GameList
    Refresh-IPList
})

if ($SelfTest) {
    Write-Host ('UI 建構 OK: ' + $form.Controls.Count + ' 個頂層控件, ' + $tabs.TabPages.Count + ' 個分頁 (SelfTest 不顯示視窗)')
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
