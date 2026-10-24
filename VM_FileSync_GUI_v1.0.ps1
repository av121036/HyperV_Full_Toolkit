# =========================================================
#  VM_FileSync_GUI_v1.0.ps1  -  VM_FileSync 引擎的 WinForms 圖形介面
#
#  純 UI 層:所有同步邏輯都呼叫 VM_FileSync_v1.0.ps1(dot-source進來),
#  本檔不重寫掛載 VHDX / robocopy / PowerShell Direct / Defender 排除等邏輯。
#
#  流程:勾選 VM -> 設定來源/目的路徑 -> (可選)VM 內加 Defender 排除 /
#        鏡像模式 / 乾跑 -> 開始同步,log 依等級即時上色顯示。
#
#  參數:
#    -SelfTest   不開視窗,只印偵測結果 + 驗證 UI 建構 (自動化驗證用)
#
#  ⚠ 本檔含中文,必須以 UTF-8 with BOM 存檔,否則 PowerShell 5.1 會用 cp950 解析而炸掉。
# =========================================================
param([switch]$SelfTest)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# =========================================================
#  dot-source 引擎(不重寫它的邏輯,只呼叫它的函式)
# =========================================================
$script:EnginePath = Join-Path $PSScriptRoot 'VM_FileSync_v1.0.ps1'
if (-not (Test-Path $script:EnginePath)) {
    [System.Windows.Forms.MessageBox]::Show(('找不到引擎檔: ' + $script:EnginePath), 'VM_FileSync GUI', 'OK', 'Error') | Out-Null
    exit 1
}
try {
    . $script:EnginePath
} catch {
    [System.Windows.Forms.MessageBox]::Show(('載入引擎失敗: ' + $_.Exception.Message), 'VM_FileSync GUI', 'OK', 'Error') | Out-Null
    exit 1
}

# 引擎頂層會把 $ErrorActionPreference 設成 'Stop'(給 CLI 用);
# GUI 事件處理常見非終止錯誤(如控件取值失敗),這裡改回 Continue,
# 避免任何一個非終止錯誤就把整個視窗炸掉。
$ErrorActionPreference = 'Continue'

# 長時間 robocopy 期間要靠這個旗標讓引擎抽送 DoEvents,視窗才不會沒回應
$script:GuiMode = $true

$script:IsElevated = $false
try { $script:IsElevated = Test-Elevated } catch { $script:IsElevated = $false }

$script:GuestCred = $null
$script:VmRows    = @()

# =========================================================
#  -SelfTest:不開視窗,先印偵測結果(UI 建構驗證在檔案最下面)
# =========================================================
if ($SelfTest) {
    Write-Host '=== SelfTest: 提權狀態 ==='
    Write-Host ('  已提權: ' + $script:IsElevated)
    Write-Host ''
    Write-Host '=== SelfTest: Hyper-V VM 清單 + 同步可行性 ==='
    try {
        Import-Module Hyper-V -ErrorAction Stop
        $vms = @(Get-VM -ErrorAction Stop | Sort-Object Name)
        foreach ($v in $vms) {
            $i = Get-VmSyncInfo -Name $v.Name
            $mark = '可同步'
            if (-not $i.Safe) { $mark = '擋下: ' + $i.BlockReason }
            Write-Host ('  ' + $i.Name + ' 狀態=' + $i.State + ' 路線=' + $i.Route + '  ' + $mark)
        }
        Write-Host ('共 ' + $vms.Count + ' 台 VM')
    } catch {
        Write-Host ('  VM 清單失敗(可能沒有系統管理員權限): ' + $_.Exception.Message)
    }
    Write-Host ''
    Write-Host 'SelfTest 偵測部分完成,接著驗證 UI 建構...'
}

# =========================================================
#  GUI 建構
# =========================================================
$uiFont     = New-Object System.Drawing.Font('LXGW WenKai Mono TC', 10)
$uiFontBold = New-Object System.Drawing.Font('LXGW WenKai Mono TC', 10, [System.Drawing.FontStyle]::Bold)
$uiFontLog  = New-Object System.Drawing.Font('LXGW WenKai Mono TC', 9)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'VM 檔案同步工具 v1.0  (VM_FileSync GUI)'
$form.Size = New-Object System.Drawing.Size(960, 860)
$form.StartPosition = 'CenterScreen'
$form.Font = $uiFont
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

# ---- log(先建,後面的函式要用它)----
$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location = New-Object System.Drawing.Point(15, 484)
$rtbLog.Size = New-Object System.Drawing.Size(920, 300)
$rtbLog.ReadOnly = $true
$rtbLog.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
$rtbLog.ForeColor = [System.Drawing.Color]::Gainsboro
$rtbLog.Font = $uiFontLog
$form.Controls.Add($rtbLog)

function Add-LogLine {
    param([string]$Msg, [System.Drawing.Color]$Color = [System.Drawing.Color]::Gainsboro)
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.SelectionColor = $Color
    $rtbLog.AppendText($Msg + "`r`n")
    $rtbLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}
function Log-Blank  { Add-LogLine '' }
function Log-Step($m) { Add-LogLine ('>> ' + $m)    ([System.Drawing.Color]::Cyan) }
function Log-OK($m)   { Add-LogLine ('[OK]  ' + $m) ([System.Drawing.Color]::LightGreen) }
function Log-Warn($m) { Add-LogLine ('[警告] ' + $m) ([System.Drawing.Color]::Orange) }
function Log-Err($m)  { Add-LogLine ('[錯誤] ' + $m) ([System.Drawing.Color]::Salmon) }
function Log-Info($m) { Add-LogLine ('      ' + $m) ([System.Drawing.Color]::Gainsboro) }

# 掛上引擎的 LogSink:引擎(含所有巢狀函式,如 Mount-VmSystemDisk / Invoke-Robocopy)
# 呼叫 Write-L 時,訊息會經這裡轉成上色的 log 行。這個 scriptblock 在頂層(此處)
# 建立,PowerShell scriptblock 用「建立時的作用域」查變數,不是「呼叫時的作用域」,
# 所以不管從多深的巢狀函式呼叫,都看得到這裡的 $rtbLog。
$script:LogSink = {
    param($msg, $level)
    switch ($level) {
        'STEP'  { Log-Step $msg }
        'OK'    { Log-OK   $msg }
        'WARN'  { Log-Warn $msg }
        'ERR'   { Log-Err  $msg }
        default { Log-Info $msg }
    }
}

# ---- 提權提示 ----
$lblElevation = New-Object System.Windows.Forms.Label
$lblElevation.Location = New-Object System.Drawing.Point(15, 10)
$lblElevation.Size = New-Object System.Drawing.Size(920, 24)
$lblElevation.Font = $uiFontBold
if ($script:IsElevated) {
    $lblElevation.Text = '已以系統管理員身分執行,可以開始同步。'
    $lblElevation.ForeColor = [System.Drawing.Color]::ForestGreen
} else {
    $lblElevation.Text = '⚠ 目前不是系統管理員身分執行,Hyper-V 與 Defender 設定會被拒。請關閉後以系統管理員身分重新執行。'
    $lblElevation.ForeColor = [System.Drawing.Color]::Red
}
$form.Controls.Add($lblElevation)

# ---- VM 清單 ----
$lblVMs = New-Object System.Windows.Forms.Label
$lblVMs.Text = '目標 VM(勾選要同步的;每列顯示狀態與可否同步):'
$lblVMs.Location = New-Object System.Drawing.Point(15, 42)
$lblVMs.AutoSize = $true
$form.Controls.Add($lblVMs)

$clbVMs = New-Object System.Windows.Forms.CheckedListBox
$clbVMs.Location = New-Object System.Drawing.Point(15, 66)
$clbVMs.Size = New-Object System.Drawing.Size(780, 170)
$clbVMs.CheckOnClick = $true
$clbVMs.HorizontalScrollbar = $true
$clbVMs.Font = $uiFont
$form.Controls.Add($clbVMs)

$btnVMRefresh = New-Object System.Windows.Forms.Button
$btnVMRefresh.Text = '重新整理 VM'
$btnVMRefresh.Location = New-Object System.Drawing.Point(805, 66)
$btnVMRefresh.Size = New-Object System.Drawing.Size(130, 34)
$form.Controls.Add($btnVMRefresh)

# ---- 來源 / 目的 ----
$lblSource = New-Object System.Windows.Forms.Label
$lblSource.Text = '來源資料夾:'
$lblSource.Location = New-Object System.Drawing.Point(15, 250)
$lblSource.AutoSize = $true
$form.Controls.Add($lblSource)

$txtSource = New-Object System.Windows.Forms.TextBox
$txtSource.Location = New-Object System.Drawing.Point(150, 246)
$txtSource.Size = New-Object System.Drawing.Size(650, 28)
$txtSource.Text = (Join-Path $env:USERPROFILE 'Desktop\share_folder')
$form.Controls.Add($txtSource)

$btnBrowseSource = New-Object System.Windows.Forms.Button
$btnBrowseSource.Text = '瀏覽...'
$btnBrowseSource.Location = New-Object System.Drawing.Point(810, 244)
$btnBrowseSource.Size = New-Object System.Drawing.Size(125, 30)
$form.Controls.Add($btnBrowseSource)

$lblDest = New-Object System.Windows.Forms.Label
$lblDest.Text = '目的路徑(VM 內):'
$lblDest.Location = New-Object System.Drawing.Point(15, 288)
$lblDest.AutoSize = $true
$form.Controls.Add($lblDest)

$txtDest = New-Object System.Windows.Forms.TextBox
$txtDest.Location = New-Object System.Drawing.Point(150, 284)
$txtDest.Size = New-Object System.Drawing.Size(300, 28)
$txtDest.Text = 'C:\VMShare'
$form.Controls.Add($txtDest)

# ---- 勾選項 ----
$chkExclusion = New-Object System.Windows.Forms.CheckBox
$chkExclusion.Text = '在 VM 內加入 Defender 排除資料夾'
$chkExclusion.Location = New-Object System.Drawing.Point(15, 324)
$chkExclusion.AutoSize = $true
$chkExclusion.Checked = $true
$form.Controls.Add($chkExclusion)

$chkMirror = New-Object System.Windows.Forms.CheckBox
$chkMirror.Text = '鏡像模式(會刪除目的端多餘檔案!)'
$chkMirror.Location = New-Object System.Drawing.Point(15, 356)
$chkMirror.AutoSize = $true
$chkMirror.Checked = $false
$form.Controls.Add($chkMirror)

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = '乾跑(不動任何檔案)'
$chkDryRun.Location = New-Object System.Drawing.Point(15, 388)
$chkDryRun.AutoSize = $true
$chkDryRun.Checked = $false
$form.Controls.Add($chkDryRun)

$chkMirror.Add_CheckedChanged({
    if ($chkMirror.Checked) {
        $chkMirror.ForeColor = [System.Drawing.Color]::Red
        $chkMirror.Font = $uiFontBold
    } else {
        $chkMirror.ForeColor = [System.Drawing.Color]::Black
        $chkMirror.Font = $uiFont
    }
})

# ---- VM 登入帳密(開機中的 VM 走 PowerShell Direct 才需要)----
$btnCred = New-Object System.Windows.Forms.Button
$btnCred.Text = '設定 VM 登入帳密'
$btnCred.Location = New-Object System.Drawing.Point(470, 320)
$btnCred.Size = New-Object System.Drawing.Size(190, 32)
$form.Controls.Add($btnCred)

$lblCredStatus = New-Object System.Windows.Forms.Label
$lblCredStatus.Text = '尚未設定(開機中的 VM 需要)'
$lblCredStatus.ForeColor = [System.Drawing.Color]::DimGray
$lblCredStatus.Location = New-Object System.Drawing.Point(670, 326)
$lblCredStatus.AutoSize = $true
$form.Controls.Add($lblCredStatus)

$btnCred.Add_Click({
    try {
        $cred = Get-Credential -Message '輸入開機中 VM 內的登入帳密(PowerShell Direct 用)'
        if ($cred) {
            $script:GuestCred = $cred
            $lblCredStatus.Text = ('已設定 (帳號: ' + $cred.UserName + ')')
            $lblCredStatus.ForeColor = [System.Drawing.Color]::ForestGreen
            Log-OK ('VM 登入帳密已設定,帳號: ' + $cred.UserName)
        } else {
            Log-Info '已取消設定 VM 登入帳密'
        }
    } catch {
        Log-Err ('設定帳密失敗: ' + $_.Exception.Message)
    }
})

# ---- 開始同步 ----
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = '開始同步'
$btnStart.Location = New-Object System.Drawing.Point(15, 424)
$btnStart.Size = New-Object System.Drawing.Size(200, 46)
$btnStart.Font = $uiFontBold
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(255, 180, 90)
if (-not $script:IsElevated) { $btnStart.Enabled = $false }
$form.Controls.Add($btnStart)

$lblStartNote = New-Object System.Windows.Forms.Label
$lblStartNote.Text = "流程:VM 關機 -> 掛載 VHDX + robocopy;VM 開機中 -> PowerShell Direct(需先設定登入帳密)。`r`n大型資料夾可能要跑一段時間,期間視窗仍會回應,請耐心等候(勿關閉)。"
$lblStartNote.Location = New-Object System.Drawing.Point(230, 424)
$lblStartNote.Size = New-Object System.Drawing.Size(705, 46)
$lblStartNote.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblStartNote)

# =========================================================
#  資料函式
# =========================================================
function Refresh-VMList {
    $clbVMs.Items.Clear()
    $script:VmRows = @()
    try {
        Import-Module Hyper-V -ErrorAction Stop
    } catch {
        Log-Err ('載入 Hyper-V 模組失敗: ' + $_.Exception.Message)
        return
    }
    $vms = $null
    try {
        $vms = @(Get-VM -ErrorAction Stop | Sort-Object Name)
    } catch {
        Log-Err ('讀取 VM 清單失敗: ' + $_.Exception.Message)
        Log-Info '請確認是用「以系統管理員身分執行」開啟本工具'
        return
    }
    foreach ($vm in $vms) {
        $info = $null
        try {
            $info = Get-VmSyncInfo -Name $vm.Name
        } catch {
            $info = [PSCustomObject]@{ Name = $vm.Name; State = [string]$vm.State; Route = $null; Safe = $false; BlockReason = ('查詢失敗: ' + $_.Exception.Message) }
        }
        $summary = $null
        if ($info.Safe) {
            $routeTxt = '關機掛載'
            if ($info.Route -ne 'offline') { $routeTxt = 'PowerShell Direct' }
            $summary = '可同步 (' + $routeTxt + ')'
        } else {
            $reason = [string]$info.BlockReason
            if ($reason.Length -gt 46) { $reason = $reason.Substring(0, 46) + '...' }
            $summary = '擋下: ' + $reason
        }
        $label = '{0,-10} 狀態={1,-9} {2}' -f $info.Name, $info.State, $summary
        $script:VmRows += [PSCustomObject]@{ Name = $info.Name; Label = $label }
        [void]$clbVMs.Items.Add($label, $false)
    }
    Log-OK ('VM 清單已更新: ' + $vms.Count + ' 台')
}

function Get-CheckedVmNames {
    $idx = @($clbVMs.CheckedIndices)
    return @($idx | ForEach-Object { $script:VmRows[$_].Name })
}

$btnVMRefresh.Add_Click({ Refresh-VMList })

$btnBrowseSource.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '選擇要同步進 VM 的來源資料夾'
    if (Test-Path $txtSource.Text) { $dlg.SelectedPath = $txtSource.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $txtSource.Text = $dlg.SelectedPath }
})

# ---- 開始同步:全部呼叫引擎,這裡不重寫同步邏輯 ----
$btnStart.Add_Click({
    $btnStart.Enabled = $false
    try {
        $names = Get-CheckedVmNames
        if (@($names).Count -eq 0) { Log-Err '請先勾選至少一個要同步的 VM'; return }

        $src = $txtSource.Text.Trim()
        if (-not $src -or -not (Test-Path $src)) { Log-Err ('來源資料夾不存在: ' + $src); return }

        $dest = $txtDest.Text.Trim()
        if (-not $dest) { Log-Err '目的路徑不能是空的'; return }

        if ($chkMirror.Checked) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                ('鏡像模式會刪除 VM 內目的資料夾中、主機來源沒有的多餘檔案。' + "`r`n`r`n" + '確定要繼續嗎?'),
                '鏡像模式確認', 'YesNo', 'Warning')
            if ($ans -ne 'Yes') { Log-Info '已取消(鏡像模式未確認)'; return }
        }

        Log-Blank
        Log-Step ('開始同步: ' + (@($names) -join ', ') + '  來源=' + $src + '  目的=' + $dest)
        if ($chkDryRun.Checked) { Log-Warn '乾跑模式:不會真的動任何檔案' }

        $results = Invoke-VmFileSync -Targets $names -SourcePath $src -GuestDest $dest `
            -WantExclusion:$chkExclusion.Checked -UseMirror:$chkMirror.Checked `
            -WhatIfOnly:$chkDryRun.Checked -Cred $script:GuestCred

        $okN   = @($results | Where-Object { $_.Result -eq '成功' -or $_.Result -eq '乾跑' }).Count
        $failN = @($results | Where-Object { $_.Result -eq '失敗' -or $_.Result -eq '擋下' }).Count
        $summaryLines = @($results | ForEach-Object { $_.VM + ': ' + $_.Result })
        $summary = $summaryLines -join "`r`n"

        Log-Blank
        Log-OK ('全部完成: 成功/乾跑 ' + $okN + ' 台,擋下/失敗 ' + $failN + ' 台')

        $icon = 'Information'
        if ($failN -gt 0) { $icon = 'Warning' }
        [System.Windows.Forms.MessageBox]::Show(('同步結束' + "`r`n`r`n" + $summary), 'VM 檔案同步 - 總結', 'OK', $icon) | Out-Null

    } catch {
        Log-Err ('同步流程發生例外: ' + $_.Exception.Message)
    } finally {
        $btnStart.Enabled = $true
    }
})

# =========================================================
#  啟動
# =========================================================
$form.Add_Shown({
    Log-Info ('VM 檔案同步工具 v1.0  |  主機: ' + $env:COMPUTERNAME)
    if (-not $script:IsElevated) {
        Log-Warn '目前不是系統管理員身分執行,已停用「開始同步」。請關閉後以系統管理員身分重新執行。'
    }
    Refresh-VMList
})

if ($SelfTest) {
    Write-Host ('UI 建構 OK: ' + $form.Controls.Count + ' 個頂層控件')
    $form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
