# =========================================================
#  VM_DiagSvc_v1.0.ps1  -  partition KMD service 深度檢查
#
#  在 VM 內部執行 (admin)。
#
#  用途:
#    GPU-PV partition 的 KMD 是 vrd.inf 註冊的 VirtualRender service。
#    此腳本檢查:
#      - VirtualRender service 實際運行狀態
#      - service 的 ImagePath 指到哪 (vrd.sys 真實路徑)
#      - 該檔案是否存在 / 版本 / 來源
#      - 全系統範圍 vrd.sys 搜尋
#      - HostDriverStore vrd 相關檔案
#      - 其他 GPU-PV 相關 service 狀態 (dxgkrnl / vmbus / BasicRender ...)
#
#  輸出可判斷:
#    A) VirtualRender Running + vrd.sys 在 → KMD 活,問題在更上層 (Win10 vrd
#       協議跟 Blackwell 不通) → 只剩升 Win11 / 換 hypervisor
#    B) VirtualRender Stopped + vrd.sys 在 → service 沒起來,試 Start-Service
#    C) vrd.sys 完全找不到 → Win10 base image 沒 ship → Win10 結構性不通
# =========================================================

$ErrorActionPreference = 'Continue'
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

# =========================================================
#  1. VirtualRender service 實際狀態
# =========================================================
W-Title '1. VirtualRender service 實際狀態'
$svc = Get-Service -Name VirtualRender -ErrorAction SilentlyContinue
if ($svc) {
    $svc | Format-List Name, DisplayName, Status, StartType
} else {
    Write-Host '  Get-Service 找不到 VirtualRender' -ForegroundColor Red
}

Write-Host '--- sc.exe query ---'
sc.exe query VirtualRender 2>&1

# =========================================================
#  2. Service registry config
# =========================================================
W-Title '2. Service registry config'
$svcReg = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\VirtualRender' -ErrorAction SilentlyContinue
if ($svcReg) {
    $svcReg | Select-Object Type, Start, ErrorControl, ImagePath, DisplayName, Group, Owners |
        Format-List

    $typeMap = @{ 1='Kernel driver'; 2='File system driver'; 4='Adapter'; 16='Own process'; 32='Share process' }
    $startMap = @{ 0='Boot'; 1='System'; 2='Auto'; 3='Manual'; 4='Disabled' }
    Write-Host ('  Type interpret  : ' + $typeMap[[int]$svcReg.Type])
    Write-Host ('  Start interpret : ' + $startMap[[int]$svcReg.Start])
} else {
    Write-Host '  registry 內找不到 VirtualRender service' -ForegroundColor Red
}

# =========================================================
#  3. ImagePath 檔案檢查
# =========================================================
W-Title '3. ImagePath 檔案實體檢查'
if ($svcReg -and $svcReg.ImagePath) {
    $raw = $svcReg.ImagePath
    $p = $raw -replace '^\\SystemRoot\\', "$env:WinDir\"
    $p = $p -replace '^\\\?\?\\', ''
    $p = $p -replace '^System32\\', "$env:WinDir\System32\"
    Write-Host ("Raw ImagePath  : $raw")
    Write-Host ("Resolved       : $p")
    $exists = Test-Path $p
    $color = if ($exists) { 'Green' } else { 'Red' }
    Write-Host ("Exists         : $exists") -ForegroundColor $color
    if ($exists) {
        $f = Get-Item $p
        Write-Host ("Size           : $($f.Length) bytes")
        Write-Host ("LastWriteTime  : $($f.LastWriteTime)")
        $v = $f.VersionInfo
        Write-Host ("FileVersion    : $($v.FileVersion)")
        Write-Host ("CompanyName    : $($v.CompanyName)")
        Write-Host ("Description    : $($v.FileDescription)")
    } else {
        Write-Host ''
        Write-Host '  *** ImagePath 指向的檔案不存在 → KMD 載不起來 ***' -ForegroundColor Red
    }
} else {
    Write-Host '  ImagePath 是空的' -ForegroundColor Red
}

# =========================================================
#  4. vrd.sys 全系統搜尋
# =========================================================
W-Title '4. vrd.sys / VrdRender* 全系統搜尋'
$hits = Get-ChildItem C:\Windows -Recurse -Filter 'vrd.sys' -ErrorAction SilentlyContinue
if ($hits) {
    foreach ($h in $hits) {
        Write-Host ("  $($h.FullName)")
        Write-Host ("    Size=$($h.Length)  Modified=$($h.LastWriteTime)")
        try {
            $v = (Get-Item $h.FullName).VersionInfo
            Write-Host ("    Version=$($v.FileVersion)  Company=$($v.CompanyName)")
        } catch {}
    }
} else {
    Write-Host '  *** 全 C:\Windows 找不到任何 vrd.sys 檔案 ***' -ForegroundColor Red
    Write-Host '  代表 Win10 base image 沒 ship 這個檔 -> 結構性不通'
}

# =========================================================
#  5. HostDriverStore vrd 相關
# =========================================================
W-Title '5. HostDriverStore vrd 相關檔'
$hostStore = 'C:\Windows\System32\HostDriverStore'
if (Test-Path $hostStore) {
    $vrdHits = Get-ChildItem $hostStore -Recurse -Filter '*vrd*' -ErrorAction SilentlyContinue |
               Select-Object -First 20
    if ($vrdHits) {
        foreach ($h in $vrdHits) {
            Write-Host ("  $($h.FullName)  ($($h.Length) bytes)")
        }
    } else {
        Write-Host '  HostDriverStore 內沒有任何 vrd* 檔'
    }
} else {
    Write-Host '  HostDriverStore 路徑不存在'
}

# =========================================================
#  6. 相關 service 全狀態
# =========================================================
W-Title '6. 相關 service 狀態'
$names = @('VirtualRender','dxgkrnl','vmbus','vmgid','BasicRender','BasicDisplay',
           'DisplayEnhancementService','VmGenerationCounter','hvcrash','3ware',
           'nvlddmkm','wvmbusvideo','HyperVideo')
foreach ($n in $names) {
    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
    if ($s) {
        Write-Host ('  {0,-30} Status={1,-10} StartType={2}' -f $s.Name, $s.Status, $s.StartType)
    } else {
        Write-Host ('  {0,-30} (not found)' -f $n) -ForegroundColor DarkGray
    }
}

# =========================================================
#  7. vrd.inf 內容摘要 (找 ServiceBinary)
# =========================================================
W-Title '7. vrd.inf 內容摘要'
$infPath = 'C:\Windows\INF\vrd.inf'
if (Test-Path $infPath) {
    $content = Get-Content $infPath -Raw -ErrorAction SilentlyContinue
    if ($content) {
        $keyLines = [regex]::Matches($content, '(?im)^\s*(ServiceBinary|ServiceType|StartType|ServiceMainFunction|DriverVer|CatalogFile|Provider)\s*=.*$')
        foreach ($m in $keyLines) {
            Write-Host ('  ' + $m.Value.Trim())
        }
    }
} else {
    Write-Host '  vrd.inf 找不到'
}

# =========================================================
#  結論
# =========================================================
W-Title '結論'

$running = ($svc -and $svc.Status -eq 'Running')
$imageExists = $false
if ($svcReg -and $svcReg.ImagePath) {
    $p = $svcReg.ImagePath -replace '^\\SystemRoot\\', "$env:WinDir\"
    $p = $p -replace '^\\\?\?\\', ''
    $imageExists = Test-Path $p
}
$anyVrdSys = ($null -ne $hits -and $hits.Count -gt 0)

if (-not $anyVrdSys) {
    Write-Host '  [C] vrd.sys 整個系統找不到' -ForegroundColor Red
    Write-Host '      Win10 base image 沒 ship vrd.sys'
    Write-Host '      -> Win10 + Blackwell GPU-PV 結構性不通'
    Write-Host '      -> 只剩升 Win11 / VMware / 主機串流'
} elseif (-not $imageExists) {
    Write-Host '  [C-2] vrd.sys 存在但 service ImagePath 指錯' -ForegroundColor Yellow
    Write-Host '       可以試把 vrd.sys 複製到 ImagePath 期望的位置'
} elseif (-not $running) {
    Write-Host '  [B] vrd.sys 在但 service 沒 Running' -ForegroundColor Yellow
    Write-Host '      試: Start-Service VirtualRender'
    Write-Host '      啟動失敗看 Event Viewer System log'
} else {
    Write-Host '  [A] VirtualRender Running + vrd.sys 都在' -ForegroundColor Green
    Write-Host '      KMD 是活的,handshake 失敗在更上層'
    Write-Host '      -> Win10 vrd 協議跟 Blackwell partition 不相容'
    Write-Host '      -> 只剩升 Win11 / VMware / 主機串流'
}

Write-Host ''
