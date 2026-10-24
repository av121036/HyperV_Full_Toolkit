# =========================================================
#  PPPoE_AutoDial_v1.0.ps1  -  寬頻(PPPoE)自動撥號設定工具
#
#  用途:在「要撥號的那台機器內」(通常是 Hyper-V 的 VM)設定
#        開機自動撥寬頻 + 斷線自動重撥。
#
#  流程:
#    步驟 1  選(或用精靈建立)寬頻連線項目
#    步驟 2  測試撥號,確認帳密與線路真的通
#    步驟 3  寫 C:\pppoe\dial.bat + 建兩個以 SYSTEM 執行的排程工作
#
#  設計取捨(不要「改良」掉):
#    - 不自己產生 rasphone.pbk。該檔格式無官方文件、隨 Windows 版本變動,
#      硬寫容易生出「看得到卻撥不動」的殘廢項目 -> 一律走系統精靈。
#    - dial.bat 一律純 ASCII 且用 goto 結構,不用 ( ) 區塊。
#      (cmd 依主控台 codepage=cp950 逐位元組解析 .bat,含中文會吃掉相鄰行;
#       路徑含 ')' 會提早截斷 if 區塊。)
#    - 排程用 SYSTEM 跑:VM 的 admin 帳號沒有密碼,Windows 不准空密碼帳號
#      做非互動登入,用該帳號設「不論登入與否」一定失敗。
#    - 呼叫原生 exe 一律走 Start-Process + 重導向到檔案再讀回,
#      不用 PowerShell 的 2>&1(5.1 會把 stderr 包成 ErrorRecord 誤判成失敗)。
#
#  參數:
#    -SelfTest   不開視窗,只印環境偵測結果 + 驗證 UI 建得起來(自動化驗證用)
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

$ErrorActionPreference = 'Continue'

# =========================================================
#  常數
# =========================================================
$script:AllUserPbk = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$script:UserPbk    = Join-Path $env:AppData     'Microsoft\Network\Connections\Pbk\rasphone.pbk'
$script:WorkDir    = 'C:\pppoe'
$script:DialBat    = 'C:\pppoe\dial.bat'
$script:DialLog    = 'C:\pppoe\dial.log'
$script:TaskBoot   = 'PPPoE-AutoDial-Boot'
$script:TaskWatch  = 'PPPoE-AutoDial-Watch'

$script:Entries    = @()

# rasdial 的結束代碼就是 RAS 錯誤碼
$script:RasErr = @{
    600 = '已經有一個作業正在進行中'
    621 = '無法開啟電話簿檔案(pbk 路徑不對或沒有權限讀)'
    623 = '找不到電話簿項目 -> 連線建在「個人」電話簿而 SYSTEM 讀不到,或名稱打錯'
    629 = '連線被遠端電腦中斷'
    651 = '數據機或連線裝置報告錯誤 -> 多半是網卡/交換器那層有問題'
    676 = '線路忙碌中'
    678 = '遠端電腦沒有回應 -> 找不到 PPPoE 伺服器,檢查外部交換器與數據機是否為橋接模式'
    691 = '使用者名稱或密碼錯誤(或該帳號不允許此連線)'
    718 = 'PPP 交涉逾時'
    720 = 'PPP 控制通訊協定交涉失敗'
    734 = 'PPP 連結控制通訊協定終止'
    756 = '這個連線已經在撥了'
    769 = '指定的目的地無法連線 -> 網路介面卡被停用'
    813 = '已經有一條使用同一裝置的連線'
}

# =========================================================
#  基礎工具
# =========================================================
function Test-Elevated {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-UiFontFamily {
    $prefer = @('LXGW WenKai Mono TC', 'Microsoft JhengHei UI', 'Microsoft JhengHei', 'Segoe UI')
    try {
        $installed = @((New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name })
        foreach ($p in $prefer) { if ($installed -contains $p) { return $p } }
    } catch {}
    return 'Segoe UI'
}

function Read-TextAuto {
    # pbk 可能是 ANSI / UTF-8 / UTF-16,依 BOM 判斷,不猜
    param([string]$Path)
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { return '' }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    return [System.Text.Encoding]::Default.GetString($bytes)
}

function Invoke-Native {
    # 跑原生 exe,回傳 [PSCustomObject]@{ Code; Text }
    param([string]$FilePath, [string]$ArgLine = '')
    $o = [System.IO.Path]::GetTempFileName()
    $e = [System.IO.Path]::GetTempFileName()
    $code = -1
    try {
        if ([string]::IsNullOrWhiteSpace($ArgLine)) {
            $p = Start-Process -FilePath $FilePath -NoNewWindow -Wait -PassThru `
                 -RedirectStandardOutput $o -RedirectStandardError $e -ErrorAction Stop
        } else {
            $p = Start-Process -FilePath $FilePath -ArgumentList $ArgLine -NoNewWindow -Wait -PassThru `
                 -RedirectStandardOutput $o -RedirectStandardError $e -ErrorAction Stop
        }
        $code = $p.ExitCode
    } catch {
        Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ Code = -1; Text = ('執行失敗: ' + $_.Exception.Message) }
    }
    $txt = ''
    try {
        # 子行程的輸出編碼跟著「主控台 codepage」走,而本檔開頭把它設成 UTF-8,
        # 所以這裡必須用 [Console]::OutputEncoding 解碼。用 ANSI(cp950)讀會變亂碼。
        $enc = $null
        try { $enc = [Console]::OutputEncoding } catch {}
        if (-not $enc) { $enc = [System.Text.Encoding]::Default }
        $a = $enc.GetString([System.IO.File]::ReadAllBytes($o))
        $b = $enc.GetString([System.IO.File]::ReadAllBytes($e))
        $txt = ($a + "`r`n" + $b).Trim()
    } catch {}
    Remove-Item $o, $e -Force -ErrorAction SilentlyContinue
    return [PSCustomObject]@{ Code = $code; Text = $txt }
}

function Test-AsciiOnly {
    param([string]$Text)
    if ($null -eq $Text) { return $true }
    foreach ($ch in $Text.ToCharArray()) { if ([int]$ch -gt 126 -or [int]$ch -lt 32) { return $false } }
    return $true
}

# =========================================================
#  電話簿 / 撥號狀態
# =========================================================
function Get-PbkEntries {
    $list = @()
    $srcs = @(
        [PSCustomObject]@{ Path = $script:AllUserPbk; Scope = '全機' },
        [PSCustomObject]@{ Path = $script:UserPbk;    Scope = '個人' }
    )
    foreach ($s in $srcs) {
        if (-not (Test-Path -LiteralPath $s.Path)) { continue }
        $text = Read-TextAuto $s.Path
        if ([string]::IsNullOrEmpty($text)) { continue }
        $cur = $null
        $isBb = $false
        foreach ($ln in ($text -split "`r?`n")) {
            $m = [regex]::Match($ln, '^\s*\[(.+)\]\s*$')
            if ($m.Success) {
                if ($cur) {
                    $list += [PSCustomObject]@{ Name = $cur; Scope = $s.Scope; Pbk = $s.Path; Broadband = $isBb }
                }
                $cur = $m.Groups[1].Value
                $isBb = $false
                continue
            }
            if ($cur -and $ln -match '(?i)PPPOE') { $isBb = $true }
        }
        if ($cur) {
            $list += [PSCustomObject]@{ Name = $cur; Scope = $s.Scope; Pbk = $s.Path; Broadband = $isBb }
        }
    }
    return $list
}

function Get-ConnectedEntries {
    # 不解析在地化文字:只比對「輸出的某一行剛好等於某個已知項目名稱」
    param([string[]]$Known)
    $r = Invoke-Native 'rasdial.exe'
    $hit = @()
    if ($r.Text) {
        $lines = @($r.Text -split "`r?`n" | ForEach-Object { $_.Trim() })
        foreach ($k in $Known) { if ($lines -contains $k) { $hit += $k } }
    }
    return $hit
}

function Get-EntryIp {
    param([string]$Entry)
    try {
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
              Where-Object { $_.InterfaceAlias -eq $Entry } | Select-Object -First 1
        if ($ip) { return $ip.IPAddress }
    } catch {}
    return ''
}

function Test-TaskExists {
    param([string]$Name)
    $r = Invoke-Native 'schtasks.exe' ('/Query /TN "' + $Name + '"')
    return ($r.Code -eq 0)
}

function Get-RasErrText {
    param([int]$Code)
    if ($Code -eq 0) { return '成功' }
    if ($script:RasErr.ContainsKey($Code)) { return ('錯誤 ' + $Code + ':' + $script:RasErr[$Code]) }
    return ('錯誤 ' + $Code)
}

# =========================================================
#  環境偵測
# =========================================================
function Get-EnvReport {
    $o = [PSCustomObject]@{
        Elevated   = (Test-Elevated)
        IsHyperVHost = $false
        HasPppoeMiniport = $false
        Note = ''
    }
    try {
        $svc = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
        if ($svc) { $o.IsHyperVHost = $true }
    } catch {}
    try {
        $ad = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop |
                Where-Object { $_.InterfaceDescription -like '*PPPOE*' })
        if ($ad.Count -gt 0) { $o.HasPppoeMiniport = $true }
    } catch { $o.Note = '無法列舉網路介面卡(權限或系統限制)' }
    return $o
}

# =========================================================
#  安裝 / 移除
# =========================================================
function New-DialBatContent {
    param([string]$Entry, [string]$Pbk, [string]$User, [string]$Pass)
    $cmd = 'rasdial "' + $Entry + '"'
    if ($User) { $cmd += ' ' + $User + ' ' + $Pass }
    if ($Pbk)  { $cmd += ' /PHONEBOOK:"' + $Pbk + '"' }

    $l = @()
    $l += '@echo off'
    $l += 'rem PPPoE auto dial - generated by PPPoE_AutoDial_v1.0.ps1'
    $l += 'rem ASCII ONLY on purpose: cmd parses .bat bytes with the console codepage.'
    $l += 'rem No ( ) blocks on purpose: a path containing ")" would terminate them early.'
    $l += 'rem'
    $l += 'rem The guard asks "is THIS dial-up entry connected", NOT "is the internet up".'
    $l += 'rem A ping guard is wrong here: the machine can still reach the internet through'
    $l += 'rem its other adapter while PPPoE is down, so it would never dial.'
    $l += 'rem "rasdial" with no args prints the connected entry names - matching the entry'
    $l += 'rem name is language independent, unlike parsing the localized status text.'
    $l += 'setlocal'
    $l += 'set "LOG=' + $script:DialLog + '"'
    $l += 'set "ENTRY=' + $Entry + '"'
    $l += 'for %%A in ("%LOG%") do if %%~zA GTR 1000000 del "%LOG%"'
    $l += 'rasdial | find /I "%ENTRY%" >nul 2>&1'
    $l += 'if not errorlevel 1 goto :online'
    $l += $cmd + ' >>"%LOG%" 2>&1'
    $l += 'echo [%date% %time%] dial exit=%errorlevel% >>"%LOG%"'
    $l += 'goto :eof'
    $l += ':online'
    $l += 'echo [%date% %time%] %ENTRY% already connected, skip >>"%LOG%"'
    $l += 'goto :eof'
    return (($l -join "`r`n") + "`r`n")
}

function Install-AutoDial {
    param([string]$Entry, [string]$Pbk, [string]$User, [string]$Pass, [int]$DelaySec, [bool]$Watch)

    $res = [PSCustomObject]@{ Ok = $false; Lines = @() }

    if (-not (Test-Path -LiteralPath $script:WorkDir)) {
        New-Item -ItemType Directory -Path $script:WorkDir -Force -ErrorAction Stop | Out-Null
        $res.Lines += ('建立目錄 ' + $script:WorkDir)
    }

    $content = New-DialBatContent -Entry $Entry -Pbk $Pbk -User $User -Pass $Pass
    [System.IO.File]::WriteAllText($script:DialBat, $content, [System.Text.Encoding]::ASCII)
    $res.Lines += ('寫出 ' + $script:DialBat + '(純 ASCII)')

    if ($User) {
        # 密碼是明碼,把目錄權限收到只有 SYSTEM + Administrators(用 SID 避開語系差異)
        $ic = Invoke-Native 'icacls.exe' ('"' + $script:WorkDir + '" /inheritance:r /grant "*S-1-5-18:(OI)(CI)F" /grant "*S-1-5-32-544:(OI)(CI)F"')
        if ($ic.Code -eq 0) { $res.Lines += '已把 C:\pppoe 權限鎖成只有 SYSTEM / Administrators 可讀' }
        else { $res.Lines += ('⚠ icacls 設定權限失敗(exit=' + $ic.Code + '),dial.bat 內的密碼目前是一般權限') }
    }

    $d = '{0:0000}:{1:00}' -f [int]([math]::Floor($DelaySec / 60)), [int]($DelaySec % 60)
    $a1 = '/Create /TN "' + $script:TaskBoot + '" /TR "' + $script:DialBat + '" /SC ONSTART /DELAY ' + $d + ' /RU SYSTEM /RL HIGHEST /F'
    $r1 = Invoke-Native 'schtasks.exe' $a1
    if ($r1.Code -ne 0) {
        $res.Lines += ('✗ 建立開機工作失敗(exit=' + $r1.Code + '):' + $r1.Text)
        return $res
    }
    $res.Lines += ('✓ 開機工作 ' + $script:TaskBoot + ' 已建立(延遲 ' + $DelaySec + ' 秒,以 SYSTEM 執行)')

    if ($Watch) {
        $a2 = '/Create /TN "' + $script:TaskWatch + '" /TR "' + $script:DialBat + '" /SC MINUTE /MO 1 /RU SYSTEM /RL HIGHEST /F'
        $r2 = Invoke-Native 'schtasks.exe' $a2
        if ($r2.Code -ne 0) {
            $res.Lines += ('✗ 建立監看工作失敗(exit=' + $r2.Code + '):' + $r2.Text)
            return $res
        }
        $res.Lines += ('✓ 監看工作 ' + $script:TaskWatch + ' 已建立(每分鐘檢查一次)')
    }

    $res.Ok = $true
    return $res
}

function Remove-AutoDial {
    $lines = @()
    foreach ($t in @($script:TaskBoot, $script:TaskWatch)) {
        $r = Invoke-Native 'schtasks.exe' ('/Delete /TN "' + $t + '" /F')
        if ($r.Code -eq 0) { $lines += ('✓ 已刪除排程 ' + $t) }
        else { $lines += ('- 排程 ' + $t + ' 不存在或刪除失敗(exit=' + $r.Code + ')') }
    }
    return $lines
}

# =========================================================
#  -SelfTest:先印偵測結果(UI 建構驗證在檔案最下面)
# =========================================================
if ($SelfTest) {
    $env0 = Get-EnvReport
    Write-Host '=== SelfTest: 環境 ==='
    Write-Host ('  已提權            : ' + $env0.Elevated)
    Write-Host ('  這台是 Hyper-V 主機: ' + $env0.IsHyperVHost)
    Write-Host ('  有 PPPOE Miniport : ' + $env0.HasPppoeMiniport)
    if ($env0.Note) { Write-Host ('  備註: ' + $env0.Note) }
    Write-Host ''
    Write-Host '=== SelfTest: 電話簿項目 ==='
    $es = @(Get-PbkEntries)
    if ($es.Count -eq 0) { Write-Host '  (找不到任何連線項目)' }
    foreach ($e in $es) {
        $bb = '一般'
        if ($e.Broadband) { $bb = '寬頻PPPoE' }
        Write-Host ('  ' + $e.Name + '  [' + $e.Scope + '] ' + $bb)
    }
    Write-Host ''
    Write-Host '=== SelfTest: 撥號 / 排程狀態 ==='
    $conn = @(Get-ConnectedEntries -Known @($es | ForEach-Object { $_.Name }))
    if ($conn.Count -eq 0) { Write-Host '  目前沒有已連線的撥號項目' }
    else { foreach ($c in $conn) { Write-Host ('  已連線: ' + $c + '  IP=' + (Get-EntryIp $c)) } }
    Write-Host ('  排程 ' + $script:TaskBoot  + ' 存在: ' + (Test-TaskExists $script:TaskBoot))
    Write-Host ('  排程 ' + $script:TaskWatch + ' 存在: ' + (Test-TaskExists $script:TaskWatch))
    Write-Host ''
    Write-Host '=== SelfTest: dial.bat 產生器(不寫檔,只驗內容)==='
    $sample = New-DialBatContent -Entry 'PPPoE' -Pbk $script:AllUserPbk -User 'user@hinet.net' -Pass 'secret'
    $bad = @($sample.ToCharArray() | Where-Object { [int]$_ -gt 126 })
    Write-Host ('  非 ASCII 位元組數: ' + $bad.Count + ' (必須是 0)')
    Write-Host ('  含 ( ) 區塊: ' + ($sample -match '\bif .*\('))
    Write-Host '  ---- 產生的 dial.bat ----'
    foreach ($sl in ($sample -split "`r?`n")) { if ($sl.Trim()) { Write-Host ('    ' + $sl) } }
    Write-Host ''
    Write-Host 'SelfTest 偵測部分完成,接著驗證 UI 建構...'
}

# =========================================================
#  GUI 建構
# =========================================================
$ff         = Get-UiFontFamily
$uiFont     = New-Object System.Drawing.Font($ff, 10)
$uiFontBold = New-Object System.Drawing.Font($ff, 10, [System.Drawing.FontStyle]::Bold)
$uiFontLog  = New-Object System.Drawing.Font($ff, 9)

$form = New-Object System.Windows.Forms.Form
$form.Text = '寬頻自動撥號設定 v1.0  (PPPoE AutoDial)'
$form.Size = New-Object System.Drawing.Size(1000, 900)
$form.StartPosition = 'CenterScreen'
$form.Font = $uiFont
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

# ---- log(先建,後面的函式要用)----
$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location = New-Object System.Drawing.Point(15, 552)
$rtbLog.Size = New-Object System.Drawing.Size(960, 292)
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
function Add-LogOk   { param([string]$M) Add-LogLine $M ([System.Drawing.Color]::FromArgb(120, 220, 130)) }
function Add-LogWarn { param([string]$M) Add-LogLine $M ([System.Drawing.Color]::FromArgb(240, 190, 90)) }
function Add-LogErr  { param([string]$M) Add-LogLine $M ([System.Drawing.Color]::FromArgb(240, 110, 110)) }
function Add-LogHead { param([string]$M) Add-LogLine ('── ' + $M + ' ' + ('─' * [math]::Max(0, 60 - $M.Length))) ([System.Drawing.Color]::FromArgb(120, 170, 240)) }

# ---- 標題 / 環境列 ----
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Location = New-Object System.Drawing.Point(15, 12)
$lblTitle.Size = New-Object System.Drawing.Size(960, 24)
$lblTitle.Font = $uiFontBold
$lblTitle.Text = '寬頻(PPPoE)自動撥號設定 — 請在「要撥號的那台機器內」執行'
$form.Controls.Add($lblTitle)

$lblEnv = New-Object System.Windows.Forms.Label
$lblEnv.Location = New-Object System.Drawing.Point(15, 40)
$lblEnv.Size = New-Object System.Drawing.Size(960, 40)
$lblEnv.Text = '環境檢查中...'
$form.Controls.Add($lblEnv)

# ---- 步驟 1 ----
$gb1 = New-Object System.Windows.Forms.GroupBox
$gb1.Location = New-Object System.Drawing.Point(15, 84)
$gb1.Size = New-Object System.Drawing.Size(960, 122)
$gb1.Text = '步驟 1   選擇寬頻連線項目'
$gb1.Font = $uiFontBold
$form.Controls.Add($gb1)

$lbl1 = New-Object System.Windows.Forms.Label
$lbl1.Location = New-Object System.Drawing.Point(15, 30)
$lbl1.Size = New-Object System.Drawing.Size(80, 22)
$lbl1.Font = $uiFont
$lbl1.Text = '連線項目:'
$gb1.Controls.Add($lbl1)

$cbEntry = New-Object System.Windows.Forms.ComboBox
$cbEntry.Location = New-Object System.Drawing.Point(100, 26)
$cbEntry.Size = New-Object System.Drawing.Size(360, 24)
$cbEntry.DropDownStyle = 'DropDownList'
$cbEntry.Font = $uiFont
$gb1.Controls.Add($cbEntry)

$btnRescan = New-Object System.Windows.Forms.Button
$btnRescan.Location = New-Object System.Drawing.Point(470, 25)
$btnRescan.Size = New-Object System.Drawing.Size(100, 27)
$btnRescan.Text = '重新掃描'
$btnRescan.Font = $uiFont
$gb1.Controls.Add($btnRescan)

$btnWizard = New-Object System.Windows.Forms.Button
$btnWizard.Location = New-Object System.Drawing.Point(580, 25)
$btnWizard.Size = New-Object System.Drawing.Size(230, 27)
$btnWizard.Text = '開啟「建立連線」精靈'
$btnWizard.Font = $uiFont
$gb1.Controls.Add($btnWizard)

$btnNcpa = New-Object System.Windows.Forms.Button
$btnNcpa.Location = New-Object System.Drawing.Point(820, 25)
$btnNcpa.Size = New-Object System.Drawing.Size(120, 27)
$btnNcpa.Text = '網路連線'
$btnNcpa.Font = $uiFont
$gb1.Controls.Add($btnNcpa)

$lblEntryHint = New-Object System.Windows.Forms.Label
$lblEntryHint.Location = New-Object System.Drawing.Point(15, 60)
$lblEntryHint.Size = New-Object System.Drawing.Size(925, 55)
$lblEntryHint.Font = $uiFont
$lblEntryHint.Text = ''
$gb1.Controls.Add($lblEntryHint)

# ---- 步驟 2 ----
$gb2 = New-Object System.Windows.Forms.GroupBox
$gb2.Location = New-Object System.Drawing.Point(15, 214)
$gb2.Size = New-Object System.Drawing.Size(960, 148)
$gb2.Text = '步驟 2   測試撥號(先確認真的撥得通,再裝自動撥號)'
$gb2.Font = $uiFontBold
$form.Controls.Add($gb2)

$lblU = New-Object System.Windows.Forms.Label
$lblU.Location = New-Object System.Drawing.Point(15, 32)
$lblU.Size = New-Object System.Drawing.Size(60, 22)
$lblU.Font = $uiFont
$lblU.Text = '帳號:'
$gb2.Controls.Add($lblU)

$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(80, 28)
$txtUser.Size = New-Object System.Drawing.Size(280, 24)
$txtUser.Font = $uiFont
$gb2.Controls.Add($txtUser)

$lblP = New-Object System.Windows.Forms.Label
$lblP.Location = New-Object System.Drawing.Point(380, 32)
$lblP.Size = New-Object System.Drawing.Size(60, 22)
$lblP.Font = $uiFont
$lblP.Text = '密碼:'
$gb2.Controls.Add($lblP)

$txtPass = New-Object System.Windows.Forms.TextBox
$txtPass.Location = New-Object System.Drawing.Point(445, 28)
$txtPass.Size = New-Object System.Drawing.Size(280, 24)
$txtPass.Font = $uiFont
$txtPass.UseSystemPasswordChar = $true
$gb2.Controls.Add($txtPass)

$lblCredHint = New-Object System.Windows.Forms.Label
$lblCredHint.Location = New-Object System.Drawing.Point(740, 32)
$lblCredHint.Size = New-Object System.Drawing.Size(205, 40)
$lblCredHint.Font = $uiFontLog
$lblCredHint.Text = '帳密只在這個視窗裡用,不會存檔(除非步驟 3 選了寫入 dial.bat)'
$gb2.Controls.Add($lblCredHint)

$btnDialCred = New-Object System.Windows.Forms.Button
$btnDialCred.Location = New-Object System.Drawing.Point(15, 66)
$btnDialCred.Size = New-Object System.Drawing.Size(200, 28)
$btnDialCred.Text = '撥號(用上面帳密)'
$btnDialCred.Font = $uiFont
$gb2.Controls.Add($btnDialCred)

$btnDialSaved = New-Object System.Windows.Forms.Button
$btnDialSaved.Location = New-Object System.Drawing.Point(225, 66)
$btnDialSaved.Size = New-Object System.Drawing.Size(250, 28)
$btnDialSaved.Text = '撥號(用連線內建帳密)'
$btnDialSaved.Font = $uiFont
$gb2.Controls.Add($btnDialSaved)

$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Location = New-Object System.Drawing.Point(485, 66)
$btnDisconnect.Size = New-Object System.Drawing.Size(120, 28)
$btnDisconnect.Text = '中斷連線'
$btnDisconnect.Font = $uiFont
$gb2.Controls.Add($btnDisconnect)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Location = New-Object System.Drawing.Point(615, 66)
$btnRefresh.Size = New-Object System.Drawing.Size(140, 28)
$btnRefresh.Text = '重新整理狀態'
$btnRefresh.Font = $uiFont
$gb2.Controls.Add($btnRefresh)

$lblDialStatus = New-Object System.Windows.Forms.Label
$lblDialStatus.Location = New-Object System.Drawing.Point(15, 104)
$lblDialStatus.Size = New-Object System.Drawing.Size(930, 36)
$lblDialStatus.Font = $uiFontBold
$lblDialStatus.Text = '撥號狀態:尚未查詢'
$gb2.Controls.Add($lblDialStatus)

# ---- 步驟 3 ----
$gb3 = New-Object System.Windows.Forms.GroupBox
$gb3.Location = New-Object System.Drawing.Point(15, 370)
$gb3.Size = New-Object System.Drawing.Size(960, 172)
$gb3.Text = '步驟 3   安裝自動撥號(開機自動撥 + 斷線自動重撥)'
$gb3.Font = $uiFontBold
$form.Controls.Add($gb3)

$rbNoCred = New-Object System.Windows.Forms.RadioButton
$rbNoCred.Location = New-Object System.Drawing.Point(15, 28)
$rbNoCred.Size = New-Object System.Drawing.Size(920, 24)
$rbNoCred.Font = $uiFont
$rbNoCred.Text = 'dial.bat 不寫帳密(建議 — 前提是上面「用連線內建帳密」撥得通)'
$rbNoCred.Checked = $true
$gb3.Controls.Add($rbNoCred)

$rbCred = New-Object System.Windows.Forms.RadioButton
$rbCred.Location = New-Object System.Drawing.Point(15, 54)
$rbCred.Size = New-Object System.Drawing.Size(920, 24)
$rbCred.Font = $uiFont
$rbCred.Text = 'dial.bat 寫入帳號密碼(明碼 — 會把 C:\pppoe 權限鎖成只有 SYSTEM / Administrators)'
$gb3.Controls.Add($rbCred)

$lblDelay = New-Object System.Windows.Forms.Label
$lblDelay.Location = New-Object System.Drawing.Point(15, 90)
$lblDelay.Size = New-Object System.Drawing.Size(95, 22)
$lblDelay.Font = $uiFont
$lblDelay.Text = '開機延遲秒:'
$gb3.Controls.Add($lblDelay)

$numDelay = New-Object System.Windows.Forms.NumericUpDown
$numDelay.Location = New-Object System.Drawing.Point(112, 86)
$numDelay.Size = New-Object System.Drawing.Size(70, 24)
$numDelay.Minimum = 0
$numDelay.Maximum = 599
$numDelay.Value = 30
$numDelay.Font = $uiFont
$gb3.Controls.Add($numDelay)

$chkWatch = New-Object System.Windows.Forms.CheckBox
$chkWatch.Location = New-Object System.Drawing.Point(200, 88)
$chkWatch.Size = New-Object System.Drawing.Size(400, 24)
$chkWatch.Font = $uiFont
$chkWatch.Text = '每分鐘檢查一次,斷線自動重撥'
$chkWatch.Checked = $true
$gb3.Controls.Add($chkWatch)

$lblTaskState = New-Object System.Windows.Forms.Label
$lblTaskState.Location = New-Object System.Drawing.Point(620, 88)
$lblTaskState.Size = New-Object System.Drawing.Size(325, 24)
$lblTaskState.Font = $uiFont
$lblTaskState.Text = '排程狀態:尚未查詢'
$gb3.Controls.Add($lblTaskState)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Location = New-Object System.Drawing.Point(15, 124)
$btnInstall.Size = New-Object System.Drawing.Size(160, 30)
$btnInstall.Text = '安裝自動撥號'
$btnInstall.Font = $uiFontBold
$gb3.Controls.Add($btnInstall)

$btnRunSys = New-Object System.Windows.Forms.Button
$btnRunSys.Location = New-Object System.Drawing.Point(185, 124)
$btnRunSys.Size = New-Object System.Drawing.Size(230, 30)
$btnRunSys.Text = '以 SYSTEM 立即試跑一次'
$btnRunSys.Font = $uiFont
$gb3.Controls.Add($btnRunSys)

$btnShowLog = New-Object System.Windows.Forms.Button
$btnShowLog.Location = New-Object System.Drawing.Point(425, 124)
$btnShowLog.Size = New-Object System.Drawing.Size(150, 30)
$btnShowLog.Text = '看 dial.log'
$btnShowLog.Font = $uiFont
$gb3.Controls.Add($btnShowLog)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Location = New-Object System.Drawing.Point(585, 124)
$btnRemove.Size = New-Object System.Drawing.Size(160, 30)
$btnRemove.Text = '移除自動撥號'
$btnRemove.Font = $uiFont
$gb3.Controls.Add($btnRemove)

# =========================================================
#  UI 行為
# =========================================================
function Get-SelectedEntry {
    if ($cbEntry.SelectedIndex -lt 0) { return $null }
    if ($cbEntry.SelectedIndex -ge $script:Entries.Count) { return $null }
    return $script:Entries[$cbEntry.SelectedIndex]
}

function Update-EntryHint {
    $e = Get-SelectedEntry
    if (-not $e) {
        $lblEntryHint.ForeColor = [System.Drawing.Color]::Firebrick
        $lblEntryHint.Text = '還沒有任何連線項目。按「開啟建立連線精靈」→ 連線到網際網路 → 寬頻 (PPPoE),' + "`r`n" +
                             '名稱請取純英數(例 PPPoE),並勾選「記住這個密碼」與「允許其他人使用這個連線」。'
        return
    }
    $msg = '電話簿:' + $e.Pbk
    if ($e.Scope -eq '個人') {
        $lblEntryHint.ForeColor = [System.Drawing.Color]::Firebrick
        $msg += "`r`n" + '⚠ 這是「個人」電話簿,SYSTEM 讀不到 → 排程撥號會回錯誤 623。'
        $msg += "`r`n" + '   請重建連線並勾選「允許其他人使用這個連線」,或把此檔複製到 ProgramData 那本。'
    } else {
        $lblEntryHint.ForeColor = [System.Drawing.Color]::DarkGreen
        $msg += "`r`n" + '✓ 全機電話簿,SYSTEM 讀得到。'
        if (-not (Test-AsciiOnly $e.Name)) {
            $lblEntryHint.ForeColor = [System.Drawing.Color]::Firebrick
            $msg += "`r`n" + '⚠ 名稱含非英數字元 → 無法寫進 .bat(cmd 會用 cp950 解析而出錯),請改名為純英數。'
        }
    }
    $lblEntryHint.Text = $msg
}

function Update-EntryList {
    $script:Entries = @(Get-PbkEntries)
    $keep = $cbEntry.Text
    $cbEntry.Items.Clear()
    foreach ($e in $script:Entries) {
        $tag = '一般'
        if ($e.Broadband) { $tag = '寬頻 PPPoE' }
        [void]$cbEntry.Items.Add($e.Name + '   [' + $e.Scope + ' / ' + $tag + ']')
    }
    if ($cbEntry.Items.Count -gt 0) {
        $idx = 0
        for ($i = 0; $i -lt $cbEntry.Items.Count; $i++) {
            if ($cbEntry.Items[$i] -eq $keep) { $idx = $i }
        }
        # 優先選寬頻項目
        if ($keep -eq '') {
            for ($i = 0; $i -lt $script:Entries.Count; $i++) {
                if ($script:Entries[$i].Broadband) { $idx = $i; break }
            }
        }
        $cbEntry.SelectedIndex = $idx
    }
    Update-EntryHint
    return $script:Entries.Count
}

function Update-Status {
    $names = @($script:Entries | ForEach-Object { $_.Name })
    $conn = @()
    if ($names.Count -gt 0) { $conn = @(Get-ConnectedEntries -Known $names) }
    if ($conn.Count -gt 0) {
        $txt = '撥號狀態:已連線 → ' + ($conn -join ', ')
        foreach ($c in $conn) {
            $ip = Get-EntryIp $c
            if ($ip) { $txt += '    對外 IP: ' + $ip }
        }
        $lblDialStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        $lblDialStatus.Text = $txt
    } else {
        $lblDialStatus.ForeColor = [System.Drawing.Color]::Firebrick
        $lblDialStatus.Text = '撥號狀態:目前沒有已連線的撥號項目'
    }

    $b = Test-TaskExists $script:TaskBoot
    $w = Test-TaskExists $script:TaskWatch
    $s = '排程狀態:開機工作 '
    if ($b) { $s += '有' } else { $s += '無' }
    $s += ' / 監看工作 '
    if ($w) { $s += '有' } else { $s += '無' }
    $lblTaskState.Text = $s
    if ($b) { $lblTaskState.ForeColor = [System.Drawing.Color]::DarkGreen }
    else { $lblTaskState.ForeColor = [System.Drawing.Color]::DimGray }
}

function Invoke-Dial {
    param([bool]$UseTypedCred)
    $e = Get-SelectedEntry
    if (-not $e) { Add-LogErr '請先選一個連線項目'; return }
    $arg = '"' + $e.Name + '"'
    if ($UseTypedCred) {
        if (-not $txtUser.Text) { Add-LogErr '請先填帳號'; return }
        $arg += ' ' + $txtUser.Text + ' ' + $txtPass.Text
    }
    $arg += ' /PHONEBOOK:"' + $e.Pbk + '"'
    Add-LogHead ('撥號 ' + $e.Name)
    $shown = $arg
    if ($UseTypedCred -and $txtPass.Text) { $shown = $shown.Replace($txtPass.Text, '********') }
    Add-LogLine ('rasdial ' + $shown)
    $r = Invoke-Native 'rasdial.exe' $arg
    if ($r.Text) { Add-LogLine $r.Text }
    if ($r.Code -eq 0) { Add-LogOk ('✓ ' + (Get-RasErrText $r.Code)) }
    else { Add-LogErr ('✗ ' + (Get-RasErrText $r.Code)) }
    Update-Status
}

$cbEntry.Add_SelectedIndexChanged({ Update-EntryHint })

$btnRescan.Add_Click({
    $n = Update-EntryList
    Update-Status
    Add-LogLine ('重新掃描電話簿,找到 ' + $n + ' 個連線項目')
})

$btnWizard.Add_Click({
    Add-LogHead '開啟建立連線精靈'
    Add-LogLine '精靈裡請選:連線到網際網路 → 寬頻 (PPPoE) → 填 ISP 帳密'
    Add-LogWarn '連線名稱請取純英數(例 PPPoE);務必勾「記住這個密碼」與「允許其他人使用這個連線」'
    Add-LogLine '建好後回來按「重新掃描」'
    $ok = $false
    try { Start-Process 'rasphone.exe' '-a' -ErrorAction Stop; $ok = $true } catch {}
    if (-not $ok) {
        try { Start-Process 'ms-settings:network-dialup' -ErrorAction Stop; $ok = $true } catch {}
    }
    if (-not $ok) {
        try { Start-Process 'control.exe' 'ncpa.cpl' -ErrorAction Stop; $ok = $true } catch {}
        Add-LogWarn '精靈叫不起來,已改開「網路連線」視窗,請自行走:設定新的連線或網路 → 連線到網際網路'
    }
    if (-not $ok) { Add-LogErr '三種開啟方式都失敗,請手動開「網路和共用中心 → 設定新的連線或網路」' }
})

$btnNcpa.Add_Click({
    try { Start-Process 'control.exe' 'ncpa.cpl' -ErrorAction Stop } catch { Add-LogErr ('開啟失敗: ' + $_.Exception.Message) }
})

$btnDialCred.Add_Click({ Invoke-Dial -UseTypedCred $true })
$btnDialSaved.Add_Click({ Invoke-Dial -UseTypedCred $false })

$btnDisconnect.Add_Click({
    $e = Get-SelectedEntry
    if (-not $e) { Add-LogErr '請先選一個連線項目'; return }
    Add-LogHead ('中斷 ' + $e.Name)
    $r = Invoke-Native 'rasdial.exe' ('"' + $e.Name + '" /DISCONNECT')
    if ($r.Text) { Add-LogLine $r.Text }
    Update-Status
})

$btnRefresh.Add_Click({ Update-Status; Add-LogLine '狀態已更新' })

$btnInstall.Add_Click({
    $e = Get-SelectedEntry
    if (-not $e) { Add-LogErr '請先選一個連線項目'; return }
    if (-not (Test-AsciiOnly $e.Name)) {
        Add-LogErr ('連線名稱「' + $e.Name + '」含非英數字元,無法寫進 .bat(cmd 用 cp950 解析會出錯)')
        Add-LogErr '請用精靈另建一個純英數名稱的連線(例 PPPoE)後重試'
        return
    }
    if (-not (Test-Elevated)) { Add-LogErr '需要系統管理員權限才能建立排程,請用 PPPoE_AutoDial_v1.0.bat 啟動'; return }

    $u = ''
    $p = ''
    if ($rbCred.Checked) {
        if (-not $txtUser.Text) { Add-LogErr '選了「寫入帳號密碼」就要填帳號'; return }
        if (-not (Test-AsciiOnly $txtUser.Text) -or -not (Test-AsciiOnly $txtPass.Text)) {
            Add-LogErr '帳號或密碼含非英數字元,不能寫進 .bat;請改用「不寫帳密」模式'
            return
        }
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "密碼會以明碼寫進 C:\pppoe\dial.bat。`r`n工具會把該目錄權限收到只有 SYSTEM / Administrators 可讀。`r`n`r`n確定要繼續嗎?",
            '確認', 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { Add-LogLine '已取消'; return }
        $u = $txtUser.Text
        $p = $txtPass.Text
    }

    Add-LogHead '安裝自動撥號'
    try {
        $r = Install-AutoDial -Entry $e.Name -Pbk $e.Pbk -User $u -Pass $p -DelaySec ([int]$numDelay.Value) -Watch ($chkWatch.Checked)
        foreach ($l in $r.Lines) {
            if ($l -like '✗*') { Add-LogErr $l }
            elseif ($l -like '⚠*') { Add-LogWarn $l }
            elseif ($l -like '✓*') { Add-LogOk $l }
            else { Add-LogLine $l }
        }
        if ($r.Ok) {
            Add-LogOk '安裝完成。建議接著按「以 SYSTEM 立即試跑一次」驗證 SYSTEM 讀得到電話簿。'
        }
    } catch {
        Add-LogErr ('安裝失敗: ' + $_.Exception.Message)
    }
    Update-Status
})

$btnRunSys.Add_Click({
    if (-not (Test-TaskExists $script:TaskBoot)) { Add-LogErr '排程還沒安裝,先按「安裝自動撥號」'; return }
    Add-LogHead '以 SYSTEM 執行 dial.bat'
    $before = ''
    if (Test-Path -LiteralPath $script:DialLog) { $before = (Read-TextAuto $script:DialLog) }
    $r = Invoke-Native 'schtasks.exe' ('/Run /TN "' + $script:TaskBoot + '"')
    if ($r.Code -ne 0) { Add-LogErr ('觸發失敗(exit=' + $r.Code + '):' + $r.Text); return }
    Add-LogLine '已觸發,等待 8 秒後讀 dial.log ...'
    for ($i = 0; $i -lt 16; $i++) {
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.Application]::DoEvents()
    }
    if (-not (Test-Path -LiteralPath $script:DialLog)) {
        Add-LogErr 'dial.log 沒有產生 → SYSTEM 可能連 dial.bat 都沒跑到,檢查排程與路徑'
        return
    }
    $after = Read-TextAuto $script:DialLog
    $new = $after.Substring([math]::Min($before.Length, $after.Length))
    if (-not $new.Trim()) { Add-LogWarn '這次沒有新的 log 行(工作可能還在跑,稍後按「看 dial.log」)' }
    else {
        foreach ($l in ($new -split "`r?`n")) {
            if ($l.Trim()) {
                if ($l -match 'exit=0') { Add-LogOk $l } elseif ($l -match 'exit=') { Add-LogErr $l } else { Add-LogLine $l }
            }
        }
    }
    Update-Status
})

$btnShowLog.Add_Click({
    if (-not (Test-Path -LiteralPath $script:DialLog)) { Add-LogWarn ('還沒有 ' + $script:DialLog); return }
    Add-LogHead 'dial.log 最後 25 行'
    $lines = @((Read-TextAuto $script:DialLog) -split "`r?`n" | Where-Object { $_.Trim() })
    $tail = $lines
    if ($lines.Count -gt 25) { $tail = $lines[($lines.Count - 25)..($lines.Count - 1)] }
    foreach ($l in $tail) { Add-LogLine $l }
})

$btnRemove.Add_Click({
    if (-not (Test-Elevated)) { Add-LogErr '需要系統管理員權限,請用 PPPoE_AutoDial_v1.0.bat 啟動'; return }
    Add-LogHead '移除自動撥號'
    foreach ($l in (Remove-AutoDial)) {
        if ($l -like '✓*') { Add-LogOk $l } else { Add-LogLine $l }
    }
    Add-LogLine ('保留 ' + $script:WorkDir + '(dial.bat 與 log 沒有刪除,要清請自行刪目錄)')
    Update-Status
})

# ---- 初始化 ----
$form.Add_Shown({
    $env1 = Get-EnvReport
    $parts = @()
    if ($env1.Elevated) { $parts += '已提權' } else { $parts += '未提權(裝排程會失敗)' }
    if ($env1.HasPppoeMiniport) { $parts += 'PPPOE Miniport 正常' } else { $parts += '找不到 PPPOE Miniport' }
    $line1 = '環境:' + ($parts -join '  |  ')
    $line2 = ''
    if ($env1.IsHyperVHost) {
        $line2 = '⚠ 偵測到 Hyper-V 主機服務(vmms)。自動撥號通常要裝在「VM 裡面」,不是主機 — 確認你跑對機器了。'
        $lblEnv.ForeColor = [System.Drawing.Color]::Firebrick
    } else {
        $lblEnv.ForeColor = [System.Drawing.Color]::DimGray
    }
    $lblEnv.Text = $line1 + "`r`n" + $line2
    if ($env1.Note) { Add-LogWarn $env1.Note }

    Add-LogHead '寬頻自動撥號設定 v1.0'
    Add-LogLine '前提(不成立的話怎麼設都撥不通):'
    Add-LogLine '  1. 主機用「有線網卡」接到「橋接模式」的數據機'
    Add-LogLine '  2. 主機建「外部 (External)」虛擬交換器綁那張有線網卡,這台 VM 接它'
    Add-LogLine '  3. Default Switch(NAT)與 Wi-Fi 都過不了 PPPoE 封包'
    Add-LogLine ''
    $n = Update-EntryList
    Add-LogLine ('掃到 ' + $n + ' 個連線項目')
    if ($n -eq 0) { Add-LogWarn '沒有任何連線項目 → 先按「開啟建立連線精靈」建一個' }
    Update-Status
})

# =========================================================
#  收尾
# =========================================================
if ($SelfTest) {
    $cnt = 0
    foreach ($c in $form.Controls) {
        $cnt++
        if ($c -is [System.Windows.Forms.GroupBox]) { $cnt += $c.Controls.Count }
    }
    Write-Host ('SelfTest: UI 建構成功,控件數 = ' + $cnt)
    Write-Host 'SelfTest: 全部完成(視窗未開啟)'
    exit 0
}

[void]$form.ShowDialog()
