# =========================================================
#  Mesa_OneClick_v1.1.ps1
#
#  GUI 一鍵部署工具:
#    0. (v1.1 新增) 自動把 C:\Mesa + TempDir 加進 Defender 排除
#       並嘗試暫時關掉即時防護(Tamper Protection 擋住也沒關係,
#       排除路徑就夠用)
#    1. 自動下載 7zr.exe (如果缺)
#    2. 自動下載 pal1000 Mesa msvc 最新版
#    3. 解壓到 C:\Mesa
#    4. 掃描 NCSOFT 等遊戲資料夾
#    5. 部署 Mesa DLL + 建 .exe.local
#    6. 設系統環境變數 (Purple 啟動的 LC.exe 才繼承到)
#    7. 還原 Defender 即時防護
#
#  使用情境:
#    GPU-PV partition 在 Win10 + Blackwell GPU 環境壞掉,
#    用 Mesa llvmpipe CPU 軟體 OpenGL 繞道。
#
#  電腦小白只要雙擊 .bat 然後按一個按鈕就好。
# =========================================================

$ErrorActionPreference = 'Stop'

# UTF-8 console
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =========================================================
#  全域設定
# =========================================================
$script:MesaDir       = 'C:\Mesa'
$script:TempDir       = Join-Path $env:TEMP 'Mesa_OneClick'
$script:Sevenzr       = Join-Path $script:TempDir '7zr.exe'
$script:SevenzrURL    = 'https://www.7-zip.org/a/7zr.exe'
$script:GithubAPI     = 'https://api.github.com/repos/pal1000/mesa-dist-win/releases/latest'
$script:FallbackURL   = 'https://github.com/pal1000/mesa-dist-win/releases/download/26.0.7/mesa3d-26.0.7-release-msvc.7z'
$script:FallbackVer   = '26.0.7'
$script:MesaEnvVars   = [ordered]@{
    'GALLIUM_DRIVER'              = 'llvmpipe'
    'MESA_LOADER_DRIVER_OVERRIDE' = 'llvmpipe'
    'LIBGL_ALWAYS_SOFTWARE'       = '1'
    'MESA_GL_VERSION_OVERRIDE'    = '4.5'
    'MESA_GLSL_VERSION_OVERRIDE'  = '450'
}

# 我們關過 RTP 嗎?結束時要還原,不然會留下沒防護的系統
$script:DefenderRTPDisabledByUs = $false

if (-not (Test-Path $script:TempDir)) {
    New-Item -Path $script:TempDir -ItemType Directory -Force | Out-Null
}

# =========================================================
#  Helper - PE 架構偵測
# =========================================================
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
#  Helper - Windows Defender 處理 (v1.1 新增)
# =========================================================
function Get-DefenderInfo {
    try {
        $s = Get-MpComputerStatus -ErrorAction Stop
        return @{
            Available        = $true
            RTPEnabled       = [bool]$s.RealTimeProtectionEnabled
            TamperProtected  = [bool]$s.IsTamperProtected
            AntivirusEnabled = [bool]$s.AntivirusEnabled
            Passive          = ($s.AMRunningMode -eq 'Passive')
        }
    } catch {
        return @{ Available = $false; RTPEnabled = $false; TamperProtected = $false }
    }
}

function Add-DefenderExclusions {
    param([string[]]$Paths)
    try {
        $cur = (Get-MpPreference -ErrorAction Stop).ExclusionPath
    } catch {
        Log "  ! 讀不到 Defender 排除清單: $($_.Exception.Message)" '!'
        return
    }
    foreach ($p in $Paths) {
        if ($cur -contains $p) {
            Log "  排除路徑已存在: $p"
            continue
        }
        try {
            Add-MpPreference -ExclusionPath $p -ErrorAction Stop
            Log "  + 加入排除路徑: $p" '+'
        } catch {
            Log "  ! 加入排除失敗 ($p): $($_.Exception.Message)" '!'
        }
    }
}

function Prep-DefenderForInstall {
    Log '--- [Step 0] 處理 Windows Defender ---'
    $info = Get-DefenderInfo
    if (-not $info.Available) {
        Log '  Defender 沒在跑(可能用第三方防毒),跳過'
        return
    }
    if ($info.Passive) {
        Log '  Defender 在 Passive 模式(有別的防毒當主防護)' '!'
    }
    if ($info.TamperProtected) {
        Log '  防竄改保護開啟 → 即時防護無法用指令關閉,只能靠排除路徑' '!'
    }

    # 不管 Tamper 如何,先把 C:\Mesa + TempDir 加進排除路徑
    Add-DefenderExclusions -Paths @($script:MesaDir, $script:TempDir)

    # 試著關 RTP(Tamper 擋住會失敗,但已經有排除路徑當保險了)
    if ($info.RTPEnabled -and -not $info.TamperProtected) {
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
            Start-Sleep -Milliseconds 800
            $after = Get-DefenderInfo
            if (-not $after.RTPEnabled) {
                Log '  ✓ 即時防護已暫時關閉' '+'
                $script:DefenderRTPDisabledByUs = $true
            } else {
                Log '  ✗ 關閉指令送出後即時防護仍開著,改靠排除路徑' '!'
            }
        } catch {
            Log "  ✗ 關閉即時防護失敗: $($_.Exception.Message),改靠排除路徑" '!'
        }
    } elseif ($info.RTPEnabled) {
        Log '  即時防護開著但有 Tamper Protection,跳過關閉(已加排除路徑)'
    } else {
        Log '  即時防護原本就是關的,不用處理'
    }
}

function Restore-DefenderAfterInstall {
    if (-not $script:DefenderRTPDisabledByUs) { return }
    Log '--- 還原 Windows Defender 即時防護 ---'
    try {
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Start-Sleep -Milliseconds 800
        $after = Get-DefenderInfo
        if ($after.RTPEnabled) {
            Log '  ✓ 即時防護已恢復' '+'
        } else {
            Log '  ! 即時防護未恢復,請手動到 Windows 安全性開啟' '!'
        }
    } catch {
        Log "  ✗ 恢復失敗: $($_.Exception.Message)" '!'
    }
    $script:DefenderRTPDisabledByUs = $false
}

# =========================================================
#  GUI 元件
# =========================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Mesa OpenGL 一鍵部署工具 v1.1'
$form.Size = New-Object System.Drawing.Size(760, 730)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 9)

# --- 標題 ---
$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = 'Mesa 軟體 OpenGL 部署 - 修復 NCSOFT 遊戲 OpenGL 問題'
$titleLabel.Location = New-Object System.Drawing.Point(15, 10)
$titleLabel.Size = New-Object System.Drawing.Size(720, 30)
$titleLabel.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 13, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = [System.Drawing.Color]::FromArgb(40, 80, 140)
$form.Controls.Add($titleLabel)

$subLabel = New-Object System.Windows.Forms.Label
$subLabel.Text = '當 VM 內 NVIDIA partition 死掉時 (GLFW Error #65542),用 CPU 軟體渲染繞道'
$subLabel.Location = New-Object System.Drawing.Point(15, 40)
$subLabel.Size = New-Object System.Drawing.Size(720, 20)
$subLabel.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($subLabel)

# --- Group 1: Mesa 狀態 ---
$grpMesa = New-Object System.Windows.Forms.GroupBox
$grpMesa.Text = ' Step 1. Mesa 軟體 OpenGL '
$grpMesa.Location = New-Object System.Drawing.Point(15, 70)
$grpMesa.Size = New-Object System.Drawing.Size(720, 80)
$form.Controls.Add($grpMesa)

$lblMesaStatus = New-Object System.Windows.Forms.Label
$lblMesaStatus.Text = '狀態: 檢查中...'
$lblMesaStatus.Location = New-Object System.Drawing.Point(15, 25)
$lblMesaStatus.Size = New-Object System.Drawing.Size(560, 20)
$grpMesa.Controls.Add($lblMesaStatus)

$lblMesaPath = New-Object System.Windows.Forms.Label
$lblMesaPath.Text = '位置: C:\Mesa'
$lblMesaPath.Location = New-Object System.Drawing.Point(15, 47)
$lblMesaPath.Size = New-Object System.Drawing.Size(560, 20)
$lblMesaPath.ForeColor = [System.Drawing.Color]::Gray
$grpMesa.Controls.Add($lblMesaPath)

$btnDownloadMesa = New-Object System.Windows.Forms.Button
$btnDownloadMesa.Text = '下載 Mesa'
$btnDownloadMesa.Location = New-Object System.Drawing.Point(600, 28)
$btnDownloadMesa.Size = New-Object System.Drawing.Size(100, 32)
$grpMesa.Controls.Add($btnDownloadMesa)

# --- Group 2: 遊戲清單 ---
$grpGames = New-Object System.Windows.Forms.GroupBox
$grpGames.Text = ' Step 2. 選擇要部署 Mesa 的遊戲 '
$grpGames.Location = New-Object System.Drawing.Point(15, 160)
$grpGames.Size = New-Object System.Drawing.Size(720, 200)
$form.Controls.Add($grpGames)

$lstGames = New-Object System.Windows.Forms.CheckedListBox
$lstGames.Location = New-Object System.Drawing.Point(15, 25)
$lstGames.Size = New-Object System.Drawing.Size(580, 160)
$lstGames.CheckOnClick = $true
$grpGames.Controls.Add($lstGames)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text = '重新掃描'
$btnScan.Location = New-Object System.Drawing.Point(600, 25)
$btnScan.Size = New-Object System.Drawing.Size(100, 32)
$grpGames.Controls.Add($btnScan)

$btnSelectAll = New-Object System.Windows.Forms.Button
$btnSelectAll.Text = '全選'
$btnSelectAll.Location = New-Object System.Drawing.Point(600, 65)
$btnSelectAll.Size = New-Object System.Drawing.Size(100, 28)
$grpGames.Controls.Add($btnSelectAll)

$btnAddCustom = New-Object System.Windows.Forms.Button
$btnAddCustom.Text = '手動加入...'
$btnAddCustom.Location = New-Object System.Drawing.Point(600, 100)
$btnAddCustom.Size = New-Object System.Drawing.Size(100, 28)
$grpGames.Controls.Add($btnAddCustom)

# --- Group 3: 動作 ---
$grpAct = New-Object System.Windows.Forms.GroupBox
$grpAct.Text = ' Step 3. 一鍵執行 '
$grpAct.Location = New-Object System.Drawing.Point(15, 370)
$grpAct.Size = New-Object System.Drawing.Size(720, 130)
$form.Controls.Add($grpAct)

# v1.1 新增:Defender 處理 checkbox
$chkAutoDefender = New-Object System.Windows.Forms.CheckBox
$chkAutoDefender.Text = '安裝前自動加 C:\Mesa 排除 + 嘗試暫關即時防護(Tamper 擋住也 OK,排除路徑能擋)'
$chkAutoDefender.Location = New-Object System.Drawing.Point(15, 22)
$chkAutoDefender.Size = New-Object System.Drawing.Size(700, 22)
$chkAutoDefender.Checked = $true
$grpAct.Controls.Add($chkAutoDefender)

$btnOneClick = New-Object System.Windows.Forms.Button
$btnOneClick.Text = '一鍵全自動 (下載 + 部署 + 設環境變數)'
$btnOneClick.Location = New-Object System.Drawing.Point(15, 50)
$btnOneClick.Size = New-Object System.Drawing.Size(380, 50)
$btnOneClick.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 11, [System.Drawing.FontStyle]::Bold)
$btnOneClick.BackColor = [System.Drawing.Color]::FromArgb(40, 130, 60)
$btnOneClick.ForeColor = [System.Drawing.Color]::White
$btnOneClick.FlatStyle = 'Flat'
$grpAct.Controls.Add($btnOneClick)

$btnDeployOnly = New-Object System.Windows.Forms.Button
$btnDeployOnly.Text = '只部署 (Mesa 已下載)'
$btnDeployOnly.Location = New-Object System.Drawing.Point(410, 50)
$btnDeployOnly.Size = New-Object System.Drawing.Size(150, 24)
$grpAct.Controls.Add($btnDeployOnly)

$btnSetEnv = New-Object System.Windows.Forms.Button
$btnSetEnv.Text = '只設環境變數'
$btnSetEnv.Location = New-Object System.Drawing.Point(410, 76)
$btnSetEnv.Size = New-Object System.Drawing.Size(150, 24)
$grpAct.Controls.Add($btnSetEnv)

$btnRemoveEnv = New-Object System.Windows.Forms.Button
$btnRemoveEnv.Text = '移除環境變數'
$btnRemoveEnv.Location = New-Object System.Drawing.Point(570, 76)
$btnRemoveEnv.Size = New-Object System.Drawing.Size(130, 24)
$grpAct.Controls.Add($btnRemoveEnv)

$btnVerify = New-Object System.Windows.Forms.Button
$btnVerify.Text = '驗證 (LC.exe 在跑時點)'
$btnVerify.Location = New-Object System.Drawing.Point(570, 50)
$btnVerify.Size = New-Object System.Drawing.Size(130, 24)
$grpAct.Controls.Add($btnVerify)

# --- 進度條 ---
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 510)
$progressBar.Size = New-Object System.Drawing.Size(720, 18)
$progressBar.Style = 'Continuous'
$form.Controls.Add($progressBar)

# --- Log 區 ---
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = '日誌:'
$lblLog.Location = New-Object System.Drawing.Point(15, 535)
$lblLog.Size = New-Object System.Drawing.Size(100, 18)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 555)
$txtLog.Size = New-Object System.Drawing.Size(720, 110)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::Black
$txtLog.ForeColor = [System.Drawing.Color]::LightGreen
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

# --- 關閉 ---
$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = '關閉'
$btnClose.Location = New-Object System.Drawing.Point(660, 670)
$btnClose.Size = New-Object System.Drawing.Size(75, 24)
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

# =========================================================
#  Log 函式
# =========================================================
function Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $stamp = Get-Date -Format 'HH:mm:ss'
    $line = "[$stamp][$Level] $Msg"
    $txtLog.AppendText($line + "`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Progress {
    param([int]$Value)
    $progressBar.Value = [Math]::Min(100, [Math]::Max(0, $Value))
    [System.Windows.Forms.Application]::DoEvents()
}

# =========================================================
#  業務邏輯
# =========================================================

function Update-MesaStatus {
    $x64 = Test-Path (Join-Path $script:MesaDir 'x64\opengl32.dll')
    $x86 = Test-Path (Join-Path $script:MesaDir 'x86\opengl32.dll')
    if ($x64 -or $x86) {
        $lblMesaStatus.Text = '狀態: ✓ Mesa 已就緒 (x64:' + $x64 + ', x86:' + $x86 + ')'
        $lblMesaStatus.ForeColor = [System.Drawing.Color]::Green
        return $true
    } else {
        $lblMesaStatus.Text = '狀態: ✗ Mesa 尚未下載'
        $lblMesaStatus.ForeColor = [System.Drawing.Color]::Red
        return $false
    }
}

function Download-File {
    param([string]$URL, [string]$Dest)
    Log "下載: $URL"
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'Mozilla/5.0 Mesa_OneClick')
    try {
        $wc.DownloadFile($URL, $Dest)
        $sz = (Get-Item $Dest).Length
        Log ("已下載 {0:N2} MB -> {1}" -f ($sz / 1MB), $Dest) '+'
        return $true
    } catch {
        Log "下載失敗: $($_.Exception.Message)" 'X'
        return $false
    } finally {
        $wc.Dispose()
    }
}

function Ensure-7zr {
    if (Test-Path $script:Sevenzr) {
        Log '7zr.exe 已存在'
        return $true
    }
    # 也檢查系統有沒有裝 7-Zip
    $sysSevenZ = @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($sysSevenZ) {
        $script:Sevenzr = $sysSevenZ
        Log "找到系統 7-Zip: $sysSevenZ"
        return $true
    }
    Log '下載 7zr.exe (約 600KB)...'
    return (Download-File $script:SevenzrURL $script:Sevenzr)
}

function Get-LatestMesaURL {
    try {
        Log '查詢 GitHub API 最新 Mesa 版本...'
        $rel = Invoke-RestMethod -Uri $script:GithubAPI -UseBasicParsing -TimeoutSec 15
        $asset = $rel.assets | Where-Object { $_.name -like 'mesa3d-*-release-msvc.7z' } | Select-Object -First 1
        if ($asset) {
            Log ("找到最新版: $($asset.name) ({0:N2} MB)" -f ($asset.size / 1MB)) '+'
            return @{ URL = $asset.browser_download_url; Name = $asset.name }
        }
    } catch {
        Log "GitHub API 查詢失敗: $($_.Exception.Message),改用 fallback URL" '!'
    }
    return @{ URL = $script:FallbackURL; Name = "mesa3d-$($script:FallbackVer)-release-msvc.7z" }
}

function Do-DownloadMesa {
    Set-Progress 5
    if (-not (Ensure-7zr)) { Log '7zr 取得失敗,中止' 'X'; return $false }
    Set-Progress 15

    $info = Get-LatestMesaURL
    $archive = Join-Path $script:TempDir $info.Name
    Set-Progress 20

    if (Test-Path $archive) {
        Log "壓縮檔已存在,跳過下載: $archive"
    } else {
        Log "下載 $($info.Name) (約 30~80 MB,請耐心等候)..."
        if (-not (Download-File $info.URL $archive)) { return $false }
    }
    Set-Progress 60

    if (Test-Path $script:MesaDir) {
        Log "C:\Mesa 已存在,刪除舊版..."
        Remove-Item $script:MesaDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $script:MesaDir -ItemType Directory -Force | Out-Null
    Set-Progress 65

    Log "解壓 $($info.Name) -> $($script:MesaDir) ..."
    $args = @('x', $archive, "-o$($script:MesaDir)", '-y')
    $p = Start-Process -FilePath $script:Sevenzr -ArgumentList $args -Wait -NoNewWindow -PassThru
    if ($p.ExitCode -ne 0) {
        Log "解壓失敗 (exit code = $($p.ExitCode))" 'X'
        return $false
    }
    Set-Progress 90

    # 有些 7z 解壓後會有一層子資料夾 mesa3d-XX.X.X\,要扁平化
    $sub = Get-ChildItem $script:MesaDir -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like 'mesa3d-*' -or $_.Name -like 'mesa-dist*' } |
           Select-Object -First 1
    if ($sub) {
        Log "扁平化子資料夾 $($sub.Name)..."
        Get-ChildItem $sub.FullName -Force | Move-Item -Destination $script:MesaDir -Force
        Remove-Item $sub.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path (Join-Path $script:MesaDir 'x64\opengl32.dll'))) {
        Log "解壓後找不到 x64\opengl32.dll,可能壓縮檔結構不對" 'X'
        return $false
    }
    Set-Progress 100
    Log "Mesa 部署完成: $($script:MesaDir)" '+'
    Update-MesaStatus | Out-Null
    return $true
}

function Scan-Games {
    $lstGames.Items.Clear()
    Log '掃描遊戲資料夾...'

    $roots = @()
    $pf86 = ${env:ProgramFiles(x86)}
    if (-not $pf86) { $pf86 = 'C:\Program Files (x86)' }

    foreach ($parent in @($pf86, 'C:\Program Files', 'D:\Games', 'E:\Games', 'D:\', 'E:\')) {
        if (-not (Test-Path $parent)) { continue }
        foreach ($nc in @('NC','NCSOFT','NCWest','NC West')) {
            $p = Join-Path $parent $nc
            if (Test-Path $p) {
                Get-ChildItem $p -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                    $roots += $_.FullName
                }
            }
        }
    }

    # 加入有 OpenGL 但 partition 死的常見遊戲(可手動加進來)
    # 例如 Minecraft launcher 之類

    # 去重
    $roots = $roots | Sort-Object -Unique

    if ($roots.Count -eq 0) {
        Log '未找到 NC/NCSOFT 系列遊戲。請按「手動加入」' '!'
    }

    foreach ($r in $roots) {
        $exeCount = (Get-ChildItem $r -Filter '*.exe' -File -ErrorAction SilentlyContinue).Count
        $label = "$r  ($exeCount 個 .exe)"
        $lstGames.Items.Add($label, $true) | Out-Null
    }
    Log ("找到 $($roots.Count) 個遊戲資料夾") '+'
}

function Get-SelectedGames {
    $list = @()
    for ($i = 0; $i -lt $lstGames.Items.Count; $i++) {
        if ($lstGames.GetItemChecked($i)) {
            $txt = $lstGames.Items[$i]
            # 拆掉 "  (X 個 .exe)" 後綴
            $path = $txt -replace '\s+\(\d+ 個 \.exe\)\s*$', ''
            $list += $path.Trim()
        }
    }
    return $list
}

function Deploy-Mesa-To {
    param([string]$GameFolder, [string]$Arch = 'auto')

    Log "部署到: $GameFolder"

    # 掃 .exe + 偵測架構
    $exes = Get-ChildItem $GameFolder -Filter '*.exe' -File -ErrorAction SilentlyContinue
    if ($exes.Count -eq 0) {
        Log "  $GameFolder 沒有 .exe,跳過" '!'
        return
    }
    $x86Count = 0; $x64Count = 0
    foreach ($e in $exes) {
        $a = Get-ExeArch $e.FullName
        if ($a -eq 'x86') { $x86Count++ }
        elseif ($a -eq 'x64') { $x64Count++ }
    }
    if ($Arch -eq 'auto') {
        if ($x64Count -ge $x86Count) { $Arch = 'x64' } else { $Arch = 'x86' }
    }
    Log "  架構: $Arch  (x86 exe: $x86Count, x64 exe: $x64Count)"

    $srcDir = Join-Path $script:MesaDir $Arch
    if (-not (Test-Path (Join-Path $srcDir 'opengl32.dll'))) {
        Log "  Mesa $Arch 缺檔,跳過" 'X'
        return
    }

    # 備份既有 DLL
    $backupRoot = Join-Path $GameFolder '_MesaBackup'
    $dllsToBackup = @('opengl32.dll','libgallium_wgl.dll','d3d10sw.dll','dxil.dll','libglapi.dll')
    foreach ($d in $dllsToBackup) {
        $src = Join-Path $GameFolder $d
        if (Test-Path $src) {
            if (-not (Test-Path $backupRoot)) {
                New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
            }
            $dst = Join-Path $backupRoot $d
            if (-not (Test-Path $dst)) {
                Copy-Item $src $dst -Force
            }
        }
    }

    # 複製 Mesa DLL
    $keyDlls = @('opengl32.dll','libgallium_wgl.dll','d3d10sw.dll','dxil.dll','libglapi.dll','graw.dll')
    $copied = 0
    foreach ($d in $keyDlls) {
        $src = Join-Path $srcDir $d
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $GameFolder $d) -Force
            $copied++
        }
    }
    Log "  已複製 $copied 個 Mesa DLL" '+'

    # 建 .exe.local (繞 KnownDLLs)
    $localCount = 0
    foreach ($e in $exes) {
        $localPath = $e.FullName + '.local'
        if (-not (Test-Path $localPath)) {
            New-Item -Path $localPath -ItemType File -Force | Out-Null
            $localCount++
        }
    }
    Log "  建立 $localCount 個 .exe.local" '+'
}

function Set-EnvVars {
    param([bool]$Remove = $false)
    foreach ($k in $script:MesaEnvVars.Keys) {
        if ($Remove) {
            [Environment]::SetEnvironmentVariable($k, $null, 'Machine')
            Log "  移除環境變數: $k" '+'
        } else {
            $v = $script:MesaEnvVars[$k]
            [Environment]::SetEnvironmentVariable($k, $v, 'Machine')
            Log "  設定環境變數: $k = $v" '+'
        }
    }
}

function Restart-Explorer {
    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Start-Process explorer.exe
        }
        Log '已重啟 explorer.exe,Purple 應該會繼承新環境變數' '+'
    } catch {
        Log "重啟 explorer 失敗: $($_.Exception.Message)" '!'
    }
}

function Do-Verify {
    Log '尋找正在跑的 LC.exe / 其他遊戲 process...'
    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Modules | Where-Object { $_.ModuleName -eq 'opengl32.dll' }
    } | Select-Object -First 10

    if (-not $procs) {
        Log '沒有 process 載入 opengl32.dll。請先啟動遊戲後再點驗證' '!'
        return
    }

    foreach ($p in $procs) {
        $mod = $p.Modules | Where-Object { $_.ModuleName -eq 'opengl32.dll' } | Select-Object -First 1
        if ($mod) {
            $isMesa = $mod.FileVersionInfo.CompanyName -match 'Mesa'
            $tag = if ($isMesa) { '✓ Mesa' } else { '✗ 系統 (沒生效)' }
            Log ("  [$tag] $($p.ProcessName) PID=$($p.Id)")
            Log ("        $($mod.FileName)")
            Log ("        v$($mod.FileVersionInfo.FileVersion)  $($mod.FileVersionInfo.CompanyName)")
        }
    }
}

# =========================================================
#  事件綁定
# =========================================================
$btnDownloadMesa.Add_Click({
    $btnDownloadMesa.Enabled = $false
    try {
        if ($chkAutoDefender.Checked) { Prep-DefenderForInstall }
        Do-DownloadMesa | Out-Null
    } finally {
        if ($chkAutoDefender.Checked) { Restore-DefenderAfterInstall }
        $btnDownloadMesa.Enabled = $true
        Set-Progress 0
    }
})

$btnScan.Add_Click({ Scan-Games })

$btnSelectAll.Add_Click({
    for ($i = 0; $i -lt $lstGames.Items.Count; $i++) {
        $lstGames.SetItemChecked($i, $true)
    }
})

$btnAddCustom.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = '選擇遊戲資料夾 (內含 .exe)'
    if ($dlg.ShowDialog() -eq 'OK') {
        $path = $dlg.SelectedPath
        $exeCount = (Get-ChildItem $path -Filter '*.exe' -File -ErrorAction SilentlyContinue).Count
        $lstGames.Items.Add("$path  ($exeCount 個 .exe)", $true) | Out-Null
    }
})

$btnDeployOnly.Add_Click({
    if (-not (Update-MesaStatus)) {
        [System.Windows.Forms.MessageBox]::Show('請先下載 Mesa', '錯誤', 'OK', 'Error') | Out-Null
        return
    }
    $games = Get-SelectedGames
    if ($games.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('請先勾選至少一個遊戲', '提示', 'OK', 'Information') | Out-Null
        return
    }
    $btnDeployOnly.Enabled = $false
    try {
        $i = 0
        foreach ($g in $games) {
            $i++
            Set-Progress ([int](100 * $i / $games.Count))
            Deploy-Mesa-To $g 'auto'
        }
        Log '部署完成' '+'
    } finally {
        $btnDeployOnly.Enabled = $true
        Set-Progress 0
    }
})

$btnSetEnv.Add_Click({
    $btnSetEnv.Enabled = $false
    try {
        Set-EnvVars -Remove $false
        $ask = [System.Windows.Forms.MessageBox]::Show(
            '環境變數已寫入。要立刻重啟 explorer.exe 嗎?(會關閉所有檔案總管視窗)',
            '確認', 'YesNo', 'Question')
        if ($ask -eq 'Yes') { Restart-Explorer }
    } finally {
        $btnSetEnv.Enabled = $true
    }
})

$btnRemoveEnv.Add_Click({
    $ask = [System.Windows.Forms.MessageBox]::Show('確定要移除 5 個 Mesa 環境變數?', '確認', 'YesNo', 'Question')
    if ($ask -eq 'Yes') {
        Set-EnvVars -Remove $true
        Log '已移除環境變數。建議登出 / 重開 VM 完全生效' '+'
    }
})

$btnVerify.Add_Click({ Do-Verify })

$btnOneClick.Add_Click({
    $btnOneClick.Enabled = $false
    try {
        Log '========== 一鍵全自動開始 ==========' '+'

        # 0. (v1.1) 處理 Defender,讓下載 + 解壓不被擋
        if ($chkAutoDefender.Checked) {
            Prep-DefenderForInstall
        } else {
            Log '步驟 0: 跳過 Defender 處理(checkbox 沒勾)'
        }

        # 1. 下載 Mesa (如果還沒)
        if (-not (Update-MesaStatus)) {
            Log '步驟 1: 下載 Mesa'
            if (-not (Do-DownloadMesa)) {
                Log '一鍵流程中止' 'X'
                return
            }
        } else {
            Log '步驟 1: Mesa 已存在,跳過下載' '+'
        }

        # 2. 部署到所有勾選的遊戲
        $games = Get-SelectedGames
        if ($games.Count -eq 0) {
            Log '步驟 2: 沒勾選任何遊戲,跳過部署' '!'
        } else {
            Log "步驟 2: 部署到 $($games.Count) 個遊戲"
            $i = 0
            foreach ($g in $games) {
                $i++
                Set-Progress ([int](100 * $i / $games.Count))
                Deploy-Mesa-To $g 'auto'
            }
            Set-Progress 0
        }

        # 3. 設環境變數
        Log '步驟 3: 寫入系統環境變數'
        Set-EnvVars -Remove $false

        # 4. 詢問重啟 explorer
        $ask = [System.Windows.Forms.MessageBox]::Show(
            "全部完成!`n`n要立刻重啟 explorer.exe 嗎?(讓 Purple 繼承新環境變數)",
            '完成', 'YesNo', 'Question')
        if ($ask -eq 'Yes') { Restart-Explorer }

        Log '========== 一鍵全自動完成 ==========' '+'
        Log '接下來:開 Purple 啟動天堂 Classic,進遊戲後點「驗證」' '+'
    } finally {
        # 5. (v1.1) 不管成功或失敗都要把 Defender 還原
        if ($chkAutoDefender.Checked) { Restore-DefenderAfterInstall }
        $btnOneClick.Enabled = $true
        Set-Progress 0
    }
})

# =========================================================
#  啟動初始化
# =========================================================
$form.Add_Shown({
    Log '工具啟動'
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole] 'Administrator')
    if (-not $isAdmin) {
        Log '警告:沒有管理員權限,設環境變數會失敗' '!'
        $btnSetEnv.Enabled = $false
        $btnRemoveEnv.Enabled = $false
        $btnOneClick.Enabled = $false
    } else {
        Log '管理員權限 OK' '+'
    }
    Update-MesaStatus | Out-Null
    Scan-Games
})

# v1.1: 萬一使用者在安裝途中按 X 關掉視窗,還是要把 RTP 還原
$form.Add_FormClosing({
    if ($script:DefenderRTPDisabledByUs) {
        Restore-DefenderAfterInstall
    }
})

# 顯示
[void]$form.ShowDialog()
