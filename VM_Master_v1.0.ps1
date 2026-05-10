# =========================================================
#  VM_Master_v1.0.ps1  -  VM 一鍵後設定工具
#                       (NVIDIA OpenGL/D3D ICD 修補 + 偽裝)
#
#  v1.0 - 將原 VM_NVFix_v1.0 + VM_Camo_v1.4 合併
#         跑一次完成兩階段,只需一次重開機
#
#  執行順序:
#    [Stage 1] NVIDIA OpenGL/D3D ICD 修補
#              - 自動偵測 nv*.inf_amd64_<hash> 並寫 vrd.inf 子鍵
#              - 備份原值 -> C:\ProgramData\VM_NVFix\backup\
#              - 建立 VM_NVFix_BootApply 排程 (每次開機重套用)
#    [Stage 2] VM 偽裝 (BIOS / MachineGuid / 電腦名稱)
#              - 用 MAC OUI 對齊到主機端設定的品牌
#              - 建立 VM_Camo_BootApply 排程 (每次開機重套用)
#    [完成]    單次重開機,兩個修改一起生效
#
#  日誌位置:
#    C:\ProgramData\VM_NVFix\boot.log
#    C:\ProgramData\VM_Camo\boot.log
#
#  失敗策略:
#    任一 Stage 失敗,腳本仍會繼續下一個 Stage,最後才重開機
#    不會因為一個錯誤就放棄整個流程
# =========================================================

$ErrorActionPreference = 'Continue'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

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
#  Helper: 倒數預設值輸入 (Server Core 沒 RawUI 時 fallback)
# =========================================================
function Read-WithDefault {
    param(
        [string]$Prompt,
        [string]$Default,
        [int]$Seconds = 5
    )
    # 沒有互動式 console (例如遠端) -> 直接回預設
    try {
        $rui = $Host.UI.RawUI
        if ($null -eq $rui) { return $Default }
    } catch { return $Default }

    $promptText = "$Prompt [預設=$Default,${Seconds}秒後自動套用]: "
    Write-Host $promptText -ForegroundColor White -NoNewline

    try {
        while ($Host.UI.RawUI.KeyAvailable) {
            [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        }

        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            if ($Host.UI.RawUI.KeyAvailable) {
                $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
                if ($key.VirtualKeyCode -eq 13) {
                    Write-Host ('(預設) ' + $Default) -ForegroundColor DarkGray
                    return $Default
                } else {
                    $first = $key.Character
                    Write-Host -NoNewline $first
                    $rest = [Console]::ReadLine()
                    $full = "$first$rest"
                    if ([string]::IsNullOrWhiteSpace($full)) { return $Default }
                    return $full.Trim()
                }
            }
            Start-Sleep -Milliseconds 100
        }
        Write-Host ('(超時) ' + $Default) -ForegroundColor DarkGray
        return $Default
    } catch {
        Write-Host ('(無互動環境) ' + $Default) -ForegroundColor DarkGray
        return $Default
    }
}

# =========================================================
#  Helper: 偽裝用的隨機字串產生器
# =========================================================
function New-RandomSerial([int]$len = 12) {
    $chars = [char[]]('ABCDEFGHJKLMNPQRSTUVWXYZ23456789')
    -join (1..$len | ForEach-Object { $chars[(Get-Random -Max $chars.Length)] })
}
function New-BiosDate {
    $d = (Get-Date).AddDays(-(Get-Random -Minimum 180 -Maximum 900))
    '{0:MM/dd/yyyy}' -f $d
}

# =========================================================
#  開場
# =========================================================
W-Title 'VM 一鍵後設定工具 v1.0 (NVFix + Camo)'

Write-Host ''
Write-Host ' 本工具會依序執行兩個階段:' -ForegroundColor White
Write-Host '   [Stage 1] NVIDIA OpenGL/D3D ICD 修補' -ForegroundColor Gray
Write-Host '             解決 GPU-PV 後 OpenGL/D3D 跳「no driver」問題' -ForegroundColor Gray
Write-Host '   [Stage 2] VM 偽裝 (BIOS + MachineGuid + 電腦名稱)' -ForegroundColor Gray
Write-Host '             讓 VM 在硬體層看起來像實體機' -ForegroundColor Gray
Write-Host ''
Write-Host ' 兩個階段都會建立開機排程,確保下次開機自動重套用。' -ForegroundColor Gray
Write-Host ' 全部跑完最後重開一次機,所有修改一起生效。' -ForegroundColor Gray
Write-Host ''

# =========================================================
#  預檢:管理員權限 + VM 環境
# =========================================================
W-Step '預檢:管理員權限 + 環境判斷'

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] 'Administrator')
if (-not $isAdmin) {
    W-Err '需要系統管理員權限'
    W-Info '請用 .bat 啟動器重跑,它會自動檢查管理員權限'
    exit 1
}
W-OK '管理員權限 OK'

$isVM = $false
try {
    $sys = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($sys.Manufacturer -match 'Microsoft|VMware|VirtualBox|innotek|QEMU|Xen' `
        -or $sys.Model -match 'Virtual|VMware|VirtualBox') {
        $isVM = $true
    }
} catch {}
if ($isVM) {
    W-OK '偵測到虛擬機環境'
} else {
    W-Warn '不像是在 VM 內,本工具是寫給 GPU-PV VM 用的'
    $cont = Read-WithDefault -Prompt '還是要繼續嗎? (Y/N)' -Default 'N' -Seconds 5
    if ($cont -notmatch '^[Yy]') { exit 1 }
}

$startConfirm = Read-WithDefault -Prompt '`n要開始執行兩階段設定嗎? (Y/N)' -Default 'Y' -Seconds 8
if ($startConfirm -notmatch '^[Yy]') {
    W-Warn '使用者取消'
    exit 0
}

# 用兩個變數記錄各階段結果,最後總結用
$stage1Result = '未執行'
$stage2Result = '未執行'

# #########################################################
# #########################################################
# ##                                                     ##
# ##   STAGE 1:  NVIDIA OpenGL/D3D ICD 修補              ##
# ##                                                     ##
# #########################################################
# #########################################################

W-Title 'Stage 1 / 2: NVIDIA OpenGL/D3D ICD 修補'

try {

    # ---------------------------------------------------------
    #  1.1 自動偵測 NVIDIA INF 資料夾
    # ---------------------------------------------------------
    W-Step '搜尋 NVIDIA 顯示驅動資料夾 (含 nvoglv64.dll)'

    $searchRoots = @(
        "$env:WinDir\System32\HostDriverStore\FileRepository",
        "$env:WinDir\System32\DriverStore\FileRepository"
    )

    $foundFolder = $null
    $foundRoot   = $null

    foreach ($root in $searchRoots) {
        if (-not (Test-Path $root)) { continue }
        $cands = Get-ChildItem $root -Filter 'nv*.inf_amd64_*' -Directory -ErrorAction SilentlyContinue
        $valid = @()
        foreach ($c in $cands) {
            # 必要:nvoglv64.dll;有 nvldumdx.dll 加分(可寫 D3D)
            if (Test-Path (Join-Path $c.FullName 'nvoglv64.dll')) { $valid += $c }
        }
        if ($valid.Count -gt 0) {
            $foundFolder = $valid | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            $foundRoot   = $root
            break
        }
    }

    if (-not $foundFolder) {
        W-Err '找不到含 nvoglv64.dll 的 NVIDIA 驅動資料夾'
        W-Info '搜尋過的位置:'
        foreach ($r in $searchRoots) { W-Info ('  ' + $r) }
        W-Info '請先在主機跑 Host_Master 把驅動搬進 VM'
        $stage1Result = '失敗:找不到 NVIDIA 驅動資料夾'
        throw 'NV_FOLDER_NOT_FOUND'
    }

    $nvFolder  = $foundFolder.FullName
    $openglDll = Join-Path $nvFolder 'nvoglv64.dll'
    $umd64Dll  = Join-Path $nvFolder 'nvldumdx.dll'
    $umd32Dll  = Join-Path $nvFolder 'nvldumd.dll'

    W-OK ('找到 NVIDIA 驅動資料夾')
    W-Info ('  名稱: ' + $foundFolder.Name)
    W-Info ('  位置: ' + $foundRoot)

    # 必要 DLL 檢查 (放寬:只必要 nvoglv64,umd 是加分項)
    $hasOgl   = Test-Path $openglDll
    $hasUmd64 = Test-Path $umd64Dll
    $hasUmd32 = Test-Path $umd32Dll

    if ($hasOgl)   { W-Info ('  [OK] nvoglv64.dll  ({0:N0} bytes)' -f (Get-Item $openglDll).Length) }
    if ($hasUmd64) { W-Info ('  [OK] nvldumdx.dll  ({0:N0} bytes)' -f (Get-Item $umd64Dll).Length) }
                else { W-Warn '  [缺] nvldumdx.dll (D3D 將跳過,只寫 OpenGL)' }
    if ($hasUmd32) { W-Info ('  [OK] nvldumd.dll   ({0:N0} bytes)' -f (Get-Item $umd32Dll).Length) }
                else { W-Warn '  [缺] nvldumd.dll  (32-bit D3D 將跳過)' }

    if (-not $hasOgl) {
        W-Err 'nvoglv64.dll 缺,無法繼續 Stage 1'
        $stage1Result = '失敗:nvoglv64.dll 缺'
        throw 'NVOGL_MISSING'
    }

    # ---------------------------------------------------------
    #  1.2 自動找 vrd.inf Class 子鍵
    # ---------------------------------------------------------
    W-Step '搜尋 GPU-PV 虛擬顯示卡 Class 子鍵 (vrd.inf)'

    $displayClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    if (-not (Test-Path $displayClass)) {
        W-Err '找不到顯示卡裝置類別登錄檔'
        $stage1Result = '失敗:Display Class 不存在'
        throw 'CLASS_KEY_MISSING'
    }

    $targets = @()
    Get-ChildItem $displayClass -ErrorAction SilentlyContinue | ForEach-Object {
        $sub = $_.PSChildName
        if ($sub -notmatch '^\d{4}$') { return }
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if (-not $props) { return }
        if ($props.InfPath -eq 'vrd.inf') {
            $targets += [PSCustomObject]@{
                SubKey     = $sub
                Path       = $_.PSPath
                DriverDesc = $props.DriverDesc
                HasOpenGL  = -not [string]::IsNullOrEmpty($props.OpenGLDriverName)
            }
        }
    }

    if ($targets.Count -eq 0) {
        W-Err '找不到任何綁到 vrd.inf 的 Class 子鍵'
        W-Info 'GPU-PV 虛擬顯示卡可能沒被建立,先回主機檢查'
        $stage1Result = '失敗:找不到 vrd.inf 子鍵'
        throw 'NO_VRD_SUBKEY'
    }

    W-OK ('找到 ' + $targets.Count + ' 個 vrd.inf 子鍵')
    foreach ($t in $targets) {
        $tag = if ($t.HasOpenGL) { ' [已設定]' } else { ' [未設定]' }
        W-Info ('  Class\' + $t.SubKey + '  ' + $t.DriverDesc + $tag)
    }

    # ---------------------------------------------------------
    #  1.3 備份 + 寫入
    # ---------------------------------------------------------
    $backupDir = 'C:\ProgramData\VM_NVFix\backup'
    if (-not (Test-Path $backupDir)) { New-Item -Path $backupDir -ItemType Directory -Force | Out-Null }
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    $umd64Multi = if ($hasUmd64) { @($umd64Dll, $umd64Dll, $umd64Dll, $umd64Dll) } else { $null }
    $umd32Multi = if ($hasUmd32) { @($umd32Dll, $umd32Dll, $umd32Dll, $umd32Dll) } else { $null }

    $writeOK = 0; $writeFail = 0
    foreach ($t in $targets) {
        W-Step ('修補 Class\' + $t.SubKey + '  (' + $t.DriverDesc + ')')

        # 備份
        try {
            $bkPath = Join-Path $backupDir ("class_{0}_{1}.reg" -f $t.SubKey, $timestamp)
            $regPath = "HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\$($t.SubKey)"
            & reg.exe export $regPath $bkPath /y | Out-Null
            W-Info ('  備份 -> ' + $bkPath)
        } catch {
            W-Warn ('  備份失敗 (繼續): ' + $_.Exception.Message)
        }

        # OpenGL ICD
        try {
            New-ItemProperty -Path $t.Path -Name 'OpenGLDriverName' -Value @($openglDll) -PropertyType MultiString -Force | Out-Null
            New-ItemProperty -Path $t.Path -Name 'OpenGLVersion' -Value 4096 -PropertyType DWord -Force | Out-Null
            W-Info '  OpenGL ICD .................. OK'
        } catch {
            W-Err ('  OpenGL ICD 寫入失敗: ' + $_.Exception.Message)
            $writeFail++
            continue
        }

        # D3D UMD x64
        if ($umd64Multi) {
            try {
                New-ItemProperty -Path $t.Path -Name 'UserModeDriverName' -Value $umd64Multi -PropertyType MultiString -Force | Out-Null
                W-Info '  D3D UMD x64 ................. OK'
            } catch {
                W-Warn ('  D3D UMD x64 寫入失敗: ' + $_.Exception.Message)
            }
        }

        # D3D UMD WoW
        if ($umd32Multi) {
            try {
                New-ItemProperty -Path $t.Path -Name 'UserModeDriverNameWoW' -Value $umd32Multi -PropertyType MultiString -Force | Out-Null
                W-Info '  D3D UMD WoW (32-bit) ........ OK'
            } catch {
                W-Warn ('  D3D UMD WoW 寫入失敗: ' + $_.Exception.Message)
            }
        }

        $writeOK++
    }

    W-OK ("Stage 1 寫入: $writeOK / $($targets.Count) 個子鍵成功")

    # ---------------------------------------------------------
    #  1.4 建立開機重套用排程 (預設 Y)
    # ---------------------------------------------------------
    Write-Host ''
    W-Step '建立 NVFix 開機重套用排程'
    $mkTask = Read-WithDefault -Prompt '要建立嗎? (Y/N,建議 Y)' -Default 'Y' -Seconds 5

    if ($mkTask -match '^[Yy]') {
        try {
            $taskFolder = 'C:\ProgramData\VM_NVFix'
            if (-not (Test-Path $taskFolder)) { New-Item -Path $taskFolder -ItemType Directory -Force | Out-Null }

            $bootScript = @'
$ErrorActionPreference = 'Continue'
$logPath = 'C:\ProgramData\VM_NVFix\boot.log'
function L($m) { Add-Content -Path $logPath -Value ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }
try {
    $roots = @(
        "$env:WinDir\System32\HostDriverStore\FileRepository",
        "$env:WinDir\System32\DriverStore\FileRepository"
    )
    $nvFolder = $null
    foreach ($r in $roots) {
        if (-not (Test-Path $r)) { continue }
        $cand = Get-ChildItem $r -Filter 'nv*.inf_amd64_*' -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path (Join-Path $_.FullName 'nvoglv64.dll') } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
        if ($cand) { $nvFolder = $cand.FullName; break }
    }
    if (-not $nvFolder) { L 'ERR: nvoglv64.dll folder not found'; return }
    $openglDll = Join-Path $nvFolder 'nvoglv64.dll'
    $umd64Dll  = Join-Path $nvFolder 'nvldumdx.dll'
    $umd32Dll  = Join-Path $nvFolder 'nvldumd.dll'
    $umd64Multi = @($umd64Dll, $umd64Dll, $umd64Dll, $umd64Dll)
    $umd32Multi = @($umd32Dll, $umd32Dll, $umd32Dll, $umd32Dll)
    $displayClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $retry = 0
    while ($retry -lt 15) {
        $found = Get-ChildItem $displayClass -ErrorAction SilentlyContinue |
                 Where-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).InfPath -eq 'vrd.inf' }
        if ($found) { break }
        Start-Sleep -Seconds 2
        $retry++
    }
    $count = 0
    Get-ChildItem $displayClass -ErrorAction SilentlyContinue | ForEach-Object {
        $sub = $_.PSChildName
        if ($sub -notmatch '^\d{4}$') { return }
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.InfPath -ne 'vrd.inf') { return }
        New-ItemProperty -Path $_.PSPath -Name 'OpenGLDriverName' -Value @($openglDll) -PropertyType MultiString -Force | Out-Null
        New-ItemProperty -Path $_.PSPath -Name 'OpenGLVersion' -Value 4096 -PropertyType DWord -Force | Out-Null
        if (Test-Path $umd64Dll) {
            New-ItemProperty -Path $_.PSPath -Name 'UserModeDriverName' -Value $umd64Multi -PropertyType MultiString -Force | Out-Null
        }
        if (Test-Path $umd32Dll) {
            New-ItemProperty -Path $_.PSPath -Name 'UserModeDriverNameWoW' -Value $umd32Multi -PropertyType MultiString -Force | Out-Null
        }
        $count++
    }
    L ("OK reapplied $count subkeys, folder=" + (Split-Path $nvFolder -Leaf))
} catch {
    L ('ERR: ' + $_.Exception.Message)
}
'@
            $bootScriptPath = Join-Path $taskFolder 'Apply_Boot.ps1'
            Set-Content -Path $bootScriptPath -Value $bootScript -Encoding UTF8

            $taskName = 'VM_NVFix_BootApply'
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                          -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootScriptPath`""
            $trigger   = New-ScheduledTaskTrigger -AtStartup
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                          -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                                  -Principal $principal -Settings $settings `
                                  -Description 'VM_NVFix - reapply NVIDIA OpenGL/D3D ICD after boot' `
                                  -Force | Out-Null
            W-OK ('排程已建立: ' + $taskName)
        } catch {
            W-Err ('排程建立失敗: ' + $_.Exception.Message)
        }
    }

    if ($writeOK -gt 0) {
        $stage1Result = "成功 ($writeOK 子鍵)"
    } else {
        $stage1Result = '失敗:沒有任何子鍵寫入成功'
    }

} catch {
    if ($_.Exception.Message -notmatch 'NV_FOLDER_NOT_FOUND|NVOGL_MISSING|CLASS_KEY_MISSING|NO_VRD_SUBKEY') {
        W-Err ('Stage 1 例外: ' + $_.Exception.Message)
        $stage1Result = ('例外: ' + $_.Exception.Message)
    }
    # 已經設好 $stage1Result,直接往下走 Stage 2
}

# #########################################################
# #########################################################
# ##                                                     ##
# ##   STAGE 2:  VM 偽裝 (BIOS / GUID / 電腦名稱)        ##
# ##                                                     ##
# #########################################################
# #########################################################

W-Title 'Stage 2 / 2: VM 偽裝 (BIOS + GUID + 電腦名稱)'

try {

    # ---------------------------------------------------------
    #  2.1 品牌預設檔
    # ---------------------------------------------------------
    $brands = [ordered]@{
        '1' = @{
            Name                  = 'ASUS ROG STRIX'
            SystemManufacturer    = 'ASUSTeK COMPUTER INC.'
            SystemProductName     = 'ROG STRIX B660-A GAMING WIFI'
            SystemFamily          = 'ROG'
            SystemSKU             = 'SKU'
            BaseBoardManufacturer = 'ASUSTeK COMPUTER INC.'
            BaseBoardProduct      = 'ROG STRIX B660-A GAMING WIFI'
            BaseBoardVersion      = 'Rev 1.xx'
            BIOSVendor            = 'American Megatrends Inc.'
            BIOSVersion           = '2801'
        }
        '2' = @{
            Name                  = 'GIGABYTE AORUS'
            SystemManufacturer    = 'Gigabyte Technology Co., Ltd.'
            SystemProductName     = 'B650 AORUS ELITE AX'
            SystemFamily          = 'AORUS'
            SystemSKU             = 'Default string'
            BaseBoardManufacturer = 'Gigabyte Technology Co., Ltd.'
            BaseBoardProduct      = 'B650 AORUS ELITE AX'
            BaseBoardVersion      = 'x.x'
            BIOSVendor            = 'American Megatrends International, LLC.'
            BIOSVersion           = 'F20'
        }
        '3' = @{
            Name                  = 'MSI MAG'
            SystemManufacturer    = 'Micro-Star International Co., Ltd.'
            SystemProductName     = 'MAG B650 TOMAHAWK WIFI (MS-7D75)'
            SystemFamily          = 'MAG'
            SystemSKU             = 'Default string'
            BaseBoardManufacturer = 'Micro-Star International Co., Ltd.'
            BaseBoardProduct      = 'MAG B650 TOMAHAWK WIFI (MS-7D75)'
            BaseBoardVersion      = '1.0'
            BIOSVendor            = 'American Megatrends International, LLC.'
            BIOSVersion           = 'A.70'
        }
        '4' = @{
            Name                  = 'ASRock Steel Legend'
            SystemManufacturer    = 'ASRock'
            SystemProductName     = 'B650 Steel Legend WiFi'
            SystemFamily          = 'Steel Legend'
            SystemSKU             = 'Default string'
            BaseBoardManufacturer = 'ASRock'
            BaseBoardProduct      = 'B650 Steel Legend WiFi'
            BaseBoardVersion      = '1.0'
            BIOSVendor            = 'American Megatrends International, LLC.'
            BIOSVersion           = '3.10'
        }
        '5' = @{
            Name                  = 'Dell OptiPlex 7090'
            SystemManufacturer    = 'Dell Inc.'
            SystemProductName     = 'OptiPlex 7090 Tower'
            SystemFamily          = 'OptiPlex'
            SystemSKU             = 'OptiPlex 7090'
            BaseBoardManufacturer = 'Dell Inc.'
            BaseBoardProduct      = '0WMCV8'
            BaseBoardVersion      = 'A01'
            BIOSVendor            = 'Dell Inc.'
            BIOSVersion           = '2.8.1'
        }
    }

    # ---------------------------------------------------------
    #  2.2 偵測 MAC OUI 對齊到品牌
    # ---------------------------------------------------------
    Write-Host ''
    Write-Host '--- MAC / 品牌對齊偵測 ---' -ForegroundColor Cyan
    $ouiMap = @{ '04-D4-C4' = '1'; '1C-1B-0D' = '2'; '00-D8-61' = '3'; '70-85-C2' = '4'; '54-BF-64' = '5' }
    $detectedKey = $null
    try {
        $nic = Get-NetAdapter -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | Select-Object -First 1
        if ($nic) {
            $macStr = $nic.MacAddress
            $oui = if ($macStr.Length -ge 8) { $macStr.Substring(0, 8) } else { '' }
            Write-Host ('  目前網卡 MAC : ' + $macStr)
            if ($ouiMap.ContainsKey($oui)) {
                $detectedKey = $ouiMap[$oui]
                Write-Host ('  對應品牌     : [' + $detectedKey + '] ' + $brands[$detectedKey].Name) -ForegroundColor Green
                Write-Host ('  預設將自動選 : [' + $detectedKey + '] (與 Host_Camo 對齊)') -ForegroundColor Green
            } else {
                Write-Host ('  MAC OUI (' + $oui + ') 不在已知品牌列表') -ForegroundColor Yellow
                Write-Host '  -> 沒跑過 Host_Camo? 預設將改用「隨機」' -ForegroundColor Yellow
            }
        }
    } catch {
        Write-Host '  (讀取 MAC 失敗,可忽略)' -ForegroundColor Gray
    }

    $defaultBrand = if ($detectedKey) { $detectedKey } else { 'R' }

    Write-Host ''
    Write-Host '請選擇品牌偽裝檔:' -ForegroundColor White
    foreach ($k in $brands.Keys) {
        $tag = if ($k -eq $detectedKey) { '  <-- MAC 對齊,預設' } else { '' }
        Write-Host ('  [{0}] {1}{2}' -f $k, $brands[$k].Name, $tag)
    }
    Write-Host '  [R] 隨機選擇' -ForegroundColor Cyan
    Write-Host ''

    $choice = Read-WithDefault -Prompt '請輸入選項 (1-5 / R)' -Default $defaultBrand -Seconds 5
    if ($choice -match '^[Rr]$') {
        $choice = (Get-Random -Minimum 1 -Maximum 6).ToString()
        W-OK ('隨機選到:' + $brands[$choice].Name)
    }
    if (-not $brands.Contains($choice)) {
        W-Err '無效的選項,Stage 2 略過'
        $stage2Result = '失敗:無效選項'
        throw 'INVALID_CHOICE'
    }
    $brand = $brands[$choice]
    W-OK ('使用品牌:' + $brand.Name)
    Write-Host ''

    $report = [ordered]@{
        '品牌'         = $brand.Name
        'MachineGuid'  = '(未設定)'
        'ProductId'    = '(未設定)'
        '電腦名稱'     = '(未設定)'
        'BaseBoard SN' = '(未設定)'
    }

    # ---------------------------------------------------------
    #  2.3 MachineGuid
    # ---------------------------------------------------------
    W-Step '修改 MachineGuid (HKLM\SOFTWARE\Microsoft\Cryptography)'
    try {
        $newGuid = [guid]::NewGuid().ToString()
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' `
                         -Name 'MachineGuid' -Value $newGuid -ErrorAction Stop
        W-OK ('MachineGuid = ' + $newGuid)
        $report['MachineGuid'] = $newGuid
    } catch { W-Err ('失敗:' + $_.Exception.Message) }

    # ---------------------------------------------------------
    #  2.4 ProductId
    # ---------------------------------------------------------
    W-Step '修改 Windows ProductId'
    try {
        $newProductId = '{0:D5}-{1:D3}-{2:D7}-{3:D5}' -f `
            (Get-Random -Maximum 100000), (Get-Random -Maximum 1000), `
            (Get-Random -Maximum 10000000), (Get-Random -Maximum 100000)
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' `
                         -Name 'ProductId' -Value $newProductId -ErrorAction Stop
        W-OK ('ProductId = ' + $newProductId)
        $report['ProductId'] = $newProductId
    } catch { W-Err ('失敗:' + $_.Exception.Message) }

    # ---------------------------------------------------------
    #  2.5 BIOS 登錄檔
    # ---------------------------------------------------------
    W-Step '修改 BIOS 偽裝登錄檔'
    $biosPath = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
    $serialNum    = New-RandomSerial 12
    $baseBoardSN  = New-RandomSerial 12
    $chassisSN    = New-RandomSerial 12
    $report['BaseBoard SN'] = $baseBoardSN

    $biosMap = [ordered]@{
        'SystemManufacturer'    = $brand.SystemManufacturer
        'SystemProductName'     = $brand.SystemProductName
        'SystemFamily'          = $brand.SystemFamily
        'SystemSKU'             = $brand.SystemSKU
        'SystemVersion'         = 'System Version'
        'SystemSerialNumber'    = $serialNum
        'BaseBoardManufacturer' = $brand.BaseBoardManufacturer
        'BaseBoardProduct'      = $brand.BaseBoardProduct
        'BaseBoardVersion'      = $brand.BaseBoardVersion
        'BaseBoardSerialNumber' = $baseBoardSN
        'BIOSVendor'            = $brand.BIOSVendor
        'BIOSVersion'           = $brand.BIOSVersion
        'BIOSReleaseDate'       = (New-BiosDate)
        'ChassisSerialNumber'   = $chassisSN
        'EnclosureType'         = 3
    }
    foreach ($k in $biosMap.Keys) {
        try {
            $v = $biosMap[$k]
            if ($v -is [int]) {
                New-ItemProperty -Path $biosPath -Name $k -Value $v -PropertyType DWord -Force | Out-Null
            } else {
                New-ItemProperty -Path $biosPath -Name $k -Value $v -PropertyType String -Force | Out-Null
            }
            W-Info ("{0,-22} = {1}" -f $k, $v)
        } catch {
            W-Err ($k + ' 失敗:' + $_.Exception.Message)
        }
    }

    # ---------------------------------------------------------
    #  2.6 SystemInformation
    # ---------------------------------------------------------
    W-Step '同步更新 SystemInformation 登錄檔'
    $sysInfoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemInformation'
    $sysInfoMap = $null
    try {
        if (-not (Test-Path $sysInfoPath)) { New-Item -Path $sysInfoPath -Force | Out-Null }
        $sysInfoMap = @{
            'BIOSVendor'         = $brand.BIOSVendor
            'BIOSVersion'        = $brand.BIOSVersion
            'SystemManufacturer' = $brand.SystemManufacturer
            'SystemProductName'  = $brand.SystemProductName
            'SystemSKU'          = $brand.SystemSKU
        }
        foreach ($k in $sysInfoMap.Keys) {
            New-ItemProperty -Path $sysInfoPath -Name $k -Value $sysInfoMap[$k] `
                             -PropertyType String -Force | Out-Null
        }
        W-OK 'SystemInformation 已更新'
    } catch { W-Err ('失敗:' + $_.Exception.Message) }

    # ---------------------------------------------------------
    #  2.7 變更電腦名稱
    # ---------------------------------------------------------
    W-Step '變更電腦名稱'
    $prefixes = @('DESKTOP', 'PC', 'WIN', 'HOME', 'USER')
    $prefix   = $prefixes[(Get-Random -Max $prefixes.Length)]
    $suffix   = -join ((48..57) + (65..90) | Get-Random -Count 7 | ForEach-Object { [char]$_ })
    $newName  = "$prefix-$suffix"
    try {
        Rename-Computer -NewName $newName -Force -ErrorAction Stop
        W-OK ('電腦名稱 = ' + $newName + '  (重開機後生效)')
        $report['電腦名稱'] = "$newName (重開生效)"
    } catch {
        W-Err ('失敗:' + $_.Exception.Message)
    }

    # ---------------------------------------------------------
    #  2.8 開機重套用排程 (預設 Y)
    # ---------------------------------------------------------
    Write-Host ''
    W-Step '建立 Camo 開機重套用排程'
    $taskYn = Read-WithDefault -Prompt '要建立嗎? (Y/N,強烈建議 Y)' -Default 'Y' -Seconds 5

    if ($taskYn -match '^[Yy]') {
        try {
            $taskFolder = 'C:\ProgramData\VM_Camo'
            if (-not (Test-Path $taskFolder)) { New-Item -Path $taskFolder -ItemType Directory -Force | Out-Null }

            $profileData = @{
                Brand    = $brand
                BiosMap  = $biosMap
                SysInfo  = $sysInfoMap
                SavedAt  = (Get-Date).ToString('o')
            }
            $profileData | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $taskFolder 'profile.json') -Encoding UTF8

            $bootScript = @'
try {
    $p = Get-Content 'C:\ProgramData\VM_Camo\profile.json' -Raw | ConvertFrom-Json
    $biosPath = 'HKLM:\HARDWARE\DESCRIPTION\System\BIOS'
    $retry = 0
    while (-not (Test-Path $biosPath) -and $retry -lt 10) {
        Start-Sleep -Seconds 2
        $retry++
    }
    foreach ($prop in $p.BiosMap.PSObject.Properties) {
        $v = $prop.Value
        if ($v -is [int] -or $v -is [long]) {
            New-ItemProperty -Path $biosPath -Name $prop.Name -Value $v -PropertyType DWord -Force | Out-Null
        } else {
            New-ItemProperty -Path $biosPath -Name $prop.Name -Value "$v" -PropertyType String -Force | Out-Null
        }
    }
    $sysInfoPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemInformation'
    if (-not (Test-Path $sysInfoPath)) { New-Item -Path $sysInfoPath -Force | Out-Null }
    foreach ($prop in $p.SysInfo.PSObject.Properties) {
        New-ItemProperty -Path $sysInfoPath -Name $prop.Name -Value "$($prop.Value)" -PropertyType String -Force | Out-Null
    }
    Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] OK - {1}" -f (Get-Date), $p.Brand.Name)
} catch {
    Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] ERR - {1}" -f (Get-Date), $_.Exception.Message)
}
try {
    Start-Sleep -Seconds 15
    $gpu = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match 'NVIDIA|GeForce|RTX|GTX' } |
           Select-Object -First 1
    if ($gpu) {
        Start-Process -FilePath 'dxdiag.exe' -ArgumentList '/whql:off' -WindowStyle Hidden
        Start-Sleep -Seconds 5
        Stop-Process -Name 'dxdiag' -Force -ErrorAction SilentlyContinue
        Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] GPU Wake OK - {1}" -f (Get-Date), $gpu.Name)
    } else {
        Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] GPU Wake Skip" -f (Get-Date))
    }
} catch {
    Add-Content -Path 'C:\ProgramData\VM_Camo\boot.log' -Value ("[{0}] GPU Wake ERR - {1}" -f (Get-Date), $_.Exception.Message)
}
'@
            $bootScriptPath = Join-Path $taskFolder 'Apply_Boot.ps1'
            Set-Content -Path $bootScriptPath -Value $bootScript -Encoding UTF8

            $taskName = 'VM_Camo_BootApply'
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$bootScriptPath`""
            $trigger   = New-ScheduledTaskTrigger -AtStartup
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
            $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                        -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
                                  -Principal $principal -Settings $settings `
                                  -Description 'VM Camouflage - reapply BIOS registry after boot' `
                                  -Force | Out-Null
            W-OK ('排程已建立: ' + $taskName)
        } catch {
            W-Err ('排程建立失敗:' + $_.Exception.Message)
        }
    }

    # ---------------------------------------------------------
    #  2.9 Stage 2 完成總結
    # ---------------------------------------------------------
    Write-Host ''
    Write-Host ' Stage 2 修改摘要:' -ForegroundColor White
    foreach ($k in $report.Keys) {
        Write-Host ('    {0,-14}: {1}' -f $k, $report[$k]) -ForegroundColor White
    }
    $stage2Result = '成功 (' + $brand.Name + ')'

} catch {
    if ($_.Exception.Message -notmatch 'INVALID_CHOICE') {
        W-Err ('Stage 2 例外: ' + $_.Exception.Message)
        $stage2Result = ('例外: ' + $_.Exception.Message)
    }
}

# #########################################################
# #########################################################
# ##                                                     ##
# ##   完成總結 + 重開機                                 ##
# ##                                                     ##
# #########################################################
# #########################################################

W-Title '兩階段執行完成 - 總結'

Write-Host ''
Write-Host '  Stage 1 (NVFix): ' -ForegroundColor White -NoNewline
$c1 = if ($stage1Result -match '^成功') { 'Green' } elseif ($stage1Result -eq '未執行') { 'Gray' } else { 'Red' }
Write-Host $stage1Result -ForegroundColor $c1

Write-Host '  Stage 2 (Camo) : ' -ForegroundColor White -NoNewline
$c2 = if ($stage2Result -match '^成功') { 'Green' } elseif ($stage2Result -eq '未執行') { 'Gray' } else { 'Red' }
Write-Host $stage2Result -ForegroundColor $c2

Write-Host ''
Write-Host '  重要提醒:' -ForegroundColor Yellow
Write-Host '   1. 電腦名稱需重新開機才會生效'
Write-Host '   2. OpenGL 修補也需重開機 (PnP 重掃時排程會自動再套一次)'
Write-Host '   3. Volume Serial(磁碟區序號)需用 VolumeID.exe 另行修改'
Write-Host '   4. MAC 位址需在主機端 Hyper-V 修改 (執行 Host_Camo)'
Write-Host '   5. 兩個排程都已建立,日誌位置:'
Write-Host '        C:\ProgramData\VM_NVFix\boot.log'
Write-Host '        C:\ProgramData\VM_Camo\boot.log'
Write-Host ''

# 重開機 (預設 Y,5 秒倒數,然後再 10 秒緩衝可 Ctrl+C)
$rb = Read-WithDefault -Prompt '要立即重新開機讓所有設定生效嗎? (Y/N)' -Default 'Y' -Seconds 5
if ($rb -match '^[Yy]') {
    W-Step '10 秒後重新開機... 按 Ctrl+C 取消'
    Start-Sleep -Seconds 10
    Restart-Computer -Force
}

Write-Host ''
