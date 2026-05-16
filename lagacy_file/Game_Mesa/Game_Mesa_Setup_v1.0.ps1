# =========================================================
#  Game_Mesa_Setup_v1.0.ps1  -  把 Mesa llvmpipe 軟體 OpenGL 部署到遊戲資料夾
#
#  解決:VM 內 NVIDIA partition D3D / Vulkan / OpenGL 全死,
#        遊戲跳 GLFW #65542 "WGL: The driver does not appear to support OpenGL"。
#        用 Mesa 軟體渲染繞過 NVIDIA partition,CPU 跑 OpenGL,老遊戲可用。
#
#  做的事:
#    1. 找遊戲資料夾 (參數 / 自動偵測 NC\* / 互動詢問)
#    2. 找 Mesa 來源資料夾 (C:\Mesa, $env:USERPROFILE\Downloads\mesa* ...)
#    3. 掃所有 .exe 偵測 32/64 bit
#    4. 複製對應架構的 Mesa DLL 到遊戲資料夾
#    5. 為每個 .exe 建立 .exe.local (繞 KnownDLLs 鎖住的 opengl32.dll)
#    6. 產生 _Launch_with_Mesa.bat,內含 GALLIUM_DRIVER=llvmpipe 等環境變數
#
#  關鍵概念 - 為什麼前面手動 copy DLL 沒效:
#    opengl32.dll 在 KnownDLLs 名單 -> Windows 永遠載 System32 那份。
#    要讓 game folder 內的 Mesa opengl32.dll 生效,必須建立同名 .local 檔
#    (空檔即可),Windows 才會啟用 AppLocal 重導向。
# =========================================================

param(
    [string]$GameFolder,
    [string]$MesaFolder,
    [ValidateSet('auto','x86','x64')][string]$Arch = 'auto'
)

$ErrorActionPreference = 'Stop'
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
function W-Step($t) { Write-Host "[*] $t" -ForegroundColor Yellow }
function W-OK($t)   { Write-Host "[+] $t" -ForegroundColor Green }
function W-Err($t)  { Write-Host "[X] $t" -ForegroundColor Red }
function W-Info($t) { Write-Host "    $t" -ForegroundColor Gray }
function W-Warn($t) { Write-Host "[!] $t" -ForegroundColor Yellow }

W-Title 'Mesa llvmpipe 軟體 OpenGL 部署工具 v1.0'

# =========================================================
#  PE 架構偵測 (讀 PE header,不用外部工具)
# =========================================================
function Get-ExeArch([string]$path) {
    try {
        $fs = [System.IO.File]::OpenRead($path)
        $br = New-Object System.IO.BinaryReader($fs)
        try {
            $fs.Position = 0x3C
            $peOffset = $br.ReadInt32()
            if ($peOffset -lt 0 -or $peOffset -gt $fs.Length - 6) { return 'Unknown' }
            $fs.Position = $peOffset
            $peSig = $br.ReadUInt32()
            if ($peSig -ne 0x4550) { return 'Unknown' }
            $machine = $br.ReadUInt16()
            switch ($machine) {
                0x014c  { return 'x86'   }
                0x8664  { return 'x64'   }
                0xAA64  { return 'arm64' }
                default { return ('Unknown(0x{0:X4})' -f $machine) }
            }
        } finally {
            $br.Close(); $fs.Close()
        }
    } catch {
        return 'Error'
    }
}

# =========================================================
#  1. 找遊戲資料夾
# =========================================================
W-Step '尋找遊戲資料夾'

if (-not $GameFolder) {
    # 預掃 NCSOFT 常見位置
    $candidates = @()
    $pfx86 = ${env:ProgramFiles(x86)}
    if (-not $pfx86) { $pfx86 = 'C:\Program Files (x86)' }
    foreach ($ncRoot in @('NC','NCSOFT','NCWest','NC West')) {
        $rootPath = Join-Path $pfx86 $ncRoot
        if (Test-Path $rootPath) {
            Get-ChildItem $rootPath -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $candidates += $_.FullName
            }
        }
    }

    if ($candidates.Count -gt 0) {
        Write-Host ''
        Write-Host '偵測到下列可能的遊戲資料夾:' -ForegroundColor White
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ('  [{0}] {1}' -f ($i+1), $candidates[$i])
        }
        Write-Host ('  [M] 手動輸入其他路徑') -ForegroundColor Gray
        Write-Host ''
        $sel = Read-Host '請輸入編號或 M'
        if ($sel -match '^[Mm]') {
            $GameFolder = Read-Host '完整路徑'
        } elseif ($sel -as [int] -and [int]$sel -ge 1 -and [int]$sel -le $candidates.Count) {
            $GameFolder = $candidates[[int]$sel - 1]
        } else {
            W-Err '無效選擇'
            exit 1
        }
    } else {
        $GameFolder = Read-Host '請輸入遊戲資料夾完整路徑'
    }
}

if (-not (Test-Path $GameFolder)) {
    W-Err "遊戲資料夾不存在: $GameFolder"
    exit 1
}
W-OK ("遊戲資料夾: $GameFolder")

# =========================================================
#  2. 找 Mesa 來源
# =========================================================
W-Step '尋找 Mesa 來源資料夾'

if (-not $MesaFolder) {
    $mesaCandidates = @()
    # 常見位置
    foreach ($p in @(
        'C:\Mesa',
        'C:\mesa-dist-win',
        "$env:USERPROFILE\Downloads\Mesa",
        "$PSScriptRoot\Mesa"
    )) {
        if (Test-Path $p) { $mesaCandidates += $p }
    }
    # Downloads 內名字像 mesa3d-XX.X.X 的
    if (Test-Path "$env:USERPROFILE\Downloads") {
        Get-ChildItem "$env:USERPROFILE\Downloads" -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like 'mesa3d-*' -or $_.Name -like 'mesa-dist*' } |
            ForEach-Object { $mesaCandidates += $_.FullName }
    }

    # 去重
    $mesaCandidates = $mesaCandidates | Select-Object -Unique

    # 驗證候選有沒有 x64\opengl32.dll 或 x86\opengl32.dll
    $valid = @()
    foreach ($m in $mesaCandidates) {
        if ((Test-Path (Join-Path $m 'x64\opengl32.dll')) -or
            (Test-Path (Join-Path $m 'x86\opengl32.dll'))) {
            $valid += $m
        }
    }

    if ($valid.Count -eq 0) {
        W-Err 'Mesa 來源找不到。請確認:'
        W-Info '  1. 已從 https://github.com/pal1000/mesa-dist-win/releases 下載'
        W-Info '     mesa3d-XX.X.X-release-msvc.7z'
        W-Info '  2. 解壓到 C:\Mesa (或下載資料夾)'
        W-Info '  3. 解壓後應該有 C:\Mesa\x64\opengl32.dll 跟 C:\Mesa\x86\opengl32.dll'
        Write-Host ''
        $MesaFolder = Read-Host '或手動輸入 Mesa 資料夾完整路徑'
    } elseif ($valid.Count -eq 1) {
        $MesaFolder = $valid[0]
        W-Info ("自動找到: $MesaFolder")
    } else {
        Write-Host ''
        Write-Host '找到多個 Mesa 來源:' -ForegroundColor White
        for ($i = 0; $i -lt $valid.Count; $i++) {
            Write-Host ('  [{0}] {1}' -f ($i+1), $valid[$i])
        }
        $sel = Read-Host '請輸入編號'
        if ($sel -as [int] -and [int]$sel -ge 1 -and [int]$sel -le $valid.Count) {
            $MesaFolder = $valid[[int]$sel - 1]
        } else {
            W-Err '無效選擇'
            exit 1
        }
    }
}

if (-not (Test-Path $MesaFolder)) {
    W-Err "Mesa 資料夾不存在: $MesaFolder"
    exit 1
}
$mesaX64 = Join-Path $MesaFolder 'x64'
$mesaX86 = Join-Path $MesaFolder 'x86'
$hasX64 = Test-Path (Join-Path $mesaX64 'opengl32.dll')
$hasX86 = Test-Path (Join-Path $mesaX86 'opengl32.dll')
if (-not $hasX64 -and -not $hasX86) {
    W-Err "Mesa 資料夾內找不到 x64\opengl32.dll 或 x86\opengl32.dll"
    W-Info '確認你解壓的是 pal1000 的 mesa3d-XX.X.X-release-msvc.7z'
    exit 1
}
W-OK ("Mesa 來源: $MesaFolder  (x64: $hasX64 | x86: $hasX86)")

# =========================================================
#  3. 掃遊戲資料夾的 .exe + 偵測架構
# =========================================================
W-Step '掃描遊戲資料夾內 .exe 並偵測架構'

$exes = Get-ChildItem $GameFolder -Filter '*.exe' -File -ErrorAction SilentlyContinue
if ($exes.Count -eq 0) {
    W-Err "遊戲資料夾內找不到任何 .exe"
    exit 1
}

$exeInfo = @()
foreach ($e in $exes) {
    $arch = Get-ExeArch $e.FullName
    $sizeMB = [math]::Round($e.Length / 1MB, 2)
    $exeInfo += [PSCustomObject]@{
        Name = $e.Name
        Arch = $arch
        SizeMB = $sizeMB
        FullPath = $e.FullName
    }
}
$exeInfo | Sort-Object SizeMB -Descending | ForEach-Object {
    W-Info ("  {0,-40} {1,-8} {2,8} MB" -f $_.Name, $_.Arch, $_.SizeMB)
}

# 自動決定主架構
$x86Count = ($exeInfo | Where-Object { $_.Arch -eq 'x86' }).Count
$x64Count = ($exeInfo | Where-Object { $_.Arch -eq 'x64' }).Count

if ($Arch -eq 'auto') {
    if ($x86Count -ge $x64Count) {
        $Arch = 'x86'
    } else {
        $Arch = 'x64'
    }
    W-Info ("自動判定主架構: $Arch  (x86 exe: $x86Count, x64 exe: $x64Count)")
} else {
    W-Info ("使用者指定架構: $Arch")
}

if ($Arch -eq 'x86' -and -not $hasX86) {
    W-Err 'Mesa 來源沒有 x86 子資料夾,無法部署 32-bit'
    exit 1
}
if ($Arch -eq 'x64' -and -not $hasX64) {
    W-Err 'Mesa 來源沒有 x64 子資料夾,無法部署 64-bit'
    exit 1
}

# =========================================================
#  4. 備份遊戲資料夾現有的 opengl32.dll (如果有)
# =========================================================
W-Step '備份遊戲資料夾現有 OpenGL 相關 DLL'
$backupRoot = Join-Path $GameFolder '_MesaBackup'
$dllsToBackup = @('opengl32.dll','libgallium_wgl.dll','d3d10sw.dll','dxil.dll','libglapi.dll')
$backedUp = 0
foreach ($d in $dllsToBackup) {
    $src = Join-Path $GameFolder $d
    if (Test-Path $src) {
        if (-not (Test-Path $backupRoot)) {
            New-Item -Path $backupRoot -ItemType Directory -Force | Out-Null
        }
        $dst = Join-Path $backupRoot $d
        if (-not (Test-Path $dst)) {
            Copy-Item $src $dst -Force
            $backedUp++
            W-Info ("  備份: $d -> _MesaBackup\")
        }
    }
}
if ($backedUp -eq 0) {
    W-Info '  (無既有 DLL 需要備份)'
} else {
    W-OK ("已備份 $backedUp 個檔案到 _MesaBackup\")
}

# =========================================================
#  5. 複製 Mesa DLL 到遊戲資料夾
# =========================================================
W-Step ("複製 Mesa $Arch DLL 到遊戲資料夾")
$srcDir = Join-Path $MesaFolder $Arch
$mesaFiles = Get-ChildItem $srcDir -File -Filter '*.dll' -ErrorAction SilentlyContinue

# 只複製關鍵 + 常用的,不要全部 (避免動到不該動的)
$keyDlls = @(
    'opengl32.dll',          # ★ 主檔,Mesa GDI loader
    'libgallium_wgl.dll',    # ★ Mesa Gallium WGL 介面
    'd3d10sw.dll',           # D3D10 軟體 (WARP-like)
    'dxil.dll',              # DXIL compiler (D3D12 用)
    'libglapi.dll',          # 舊版 Mesa 用,新版可能沒有
    'graw.dll'               # Mesa galahad (zink 用)
)

$copied = 0
foreach ($d in $keyDlls) {
    $src = Join-Path $srcDir $d
    if (Test-Path $src) {
        $dst = Join-Path $GameFolder $d
        Copy-Item $src $dst -Force
        $copied++
        $sz = [math]::Round((Get-Item $src).Length / 1KB, 0)
        W-Info ("  [+] $d  ($sz KB)")
    }
}
W-OK ("複製 $copied 個 Mesa DLL")

# =========================================================
#  6. 建 .exe.local (繞 KnownDLLs)
# =========================================================
W-Step "建立 .exe.local (繞過 opengl32.dll KnownDLLs 鎖)"
$localCreated = 0
foreach ($e in $exeInfo) {
    $localPath = $e.FullPath + '.local'
    if (-not (Test-Path $localPath)) {
        # 空檔即可
        New-Item -Path $localPath -ItemType File -Force | Out-Null
        $localCreated++
        W-Info ("  [+] $($e.Name).local")
    } else {
        W-Info ("  (已存在) $($e.Name).local")
    }
}
W-OK ("建立 $localCreated 個 .local 檔")

# =========================================================
#  7. 產生 _Launch_with_Mesa.bat
# =========================================================
W-Step '產生啟動腳本 _Launch_with_Mesa.bat'

# 選最大的 .exe 當預設啟動目標 (通常是主程式)
$mainExe = $exeInfo | Sort-Object SizeMB -Descending | Select-Object -First 1

$launcherPath = Join-Path $GameFolder '_Launch_with_Mesa.bat'
$launcherContent = @"
@echo off
REM ============================================================
REM  _Launch_with_Mesa.bat - 用 Mesa llvmpipe 軟體 OpenGL 啟動遊戲
REM
REM  由 Game_Mesa_Setup_v1.0 自動產生於 $(Get-Date -Format 'yyyy-MM-dd HH:mm')
REM
REM  環境變數:
REM    GALLIUM_DRIVER=llvmpipe          -> Mesa 用 llvmpipe (CPU OpenGL)
REM    MESA_LOADER_DRIVER_OVERRIDE      -> 強制 llvmpipe,不要 fallback
REM    LIBGL_ALWAYS_SOFTWARE=1          -> 100% 軟體渲染
REM    MESA_GL_VERSION_OVERRIDE         -> 對遊戲謊報 OpenGL 版本
REM ============================================================
title $($mainExe.Name) (Mesa llvmpipe)

cd /d "$GameFolder"

set GALLIUM_DRIVER=llvmpipe
set MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
set LIBGL_ALWAYS_SOFTWARE=1
set MESA_GL_VERSION_OVERRIDE=4.5
set MESA_GLSL_VERSION_OVERRIDE=450

REM 如果遊戲在 NCSOFT Purple 啟動器內,你可能要改下面這行
REM 換成從 Purple 啟動而不是直接呼叫 .exe
start "" "$($mainExe.FullPath)" %*

REM 如果要立刻看 console log 不要 start 直接呼叫:
REM "$($mainExe.FullPath)" %*
"@

Set-Content -LiteralPath $launcherPath -Value $launcherContent -Encoding UTF8 -Force
W-OK ("已建立: $launcherPath")
W-Info ('  預設啟動: ' + $mainExe.Name)

# =========================================================
#  8. 結尾說明
# =========================================================
W-Title '完成'
Write-Host ''
Write-Host ' 使用方式:' -ForegroundColor White
Write-Host "   1. 進入遊戲資料夾: $GameFolder" -ForegroundColor Gray
Write-Host '   2. 雙擊 _Launch_with_Mesa.bat 啟動' -ForegroundColor Gray
Write-Host '   3. 第一次跑 Mesa llvmpipe 編譯 shader 會有點頓,等 10~30 秒' -ForegroundColor Gray
Write-Host ''
Write-Host ' 如果 NCSOFT 遊戲要從 Purple 啟動器跑:' -ForegroundColor White
Write-Host '   - Purple 啟動器先正常開' -ForegroundColor Gray
Write-Host '   - 但 Purple 啟動完之後跑出來的遊戲 process 也要在「同一個' -ForegroundColor Gray
Write-Host '     資料夾」+ 繼承 Purple 的環境變數才會用到 Mesa' -ForegroundColor Gray
Write-Host '   - 較簡單做法:把 _Launch_with_Mesa.bat 內的環境變數設' -ForegroundColor Gray
Write-Host '     成「使用者環境變數」(全域生效),Purple 跑的子程式就會吃到' -ForegroundColor Gray
Write-Host ''
Write-Host ' 還是不能跑的話檢查:' -ForegroundColor White
Write-Host '   1. 工作管理員看遊戲 process 是 32-bit (*32) 還 64-bit' -ForegroundColor Gray
Write-Host '      不對的話重跑此工具加參數: -Arch x86 或 -Arch x64' -ForegroundColor Gray
Write-Host '   2. 確認遊戲資料夾內有 opengl32.dll + libgallium_wgl.dll' -ForegroundColor Gray
Write-Host '      跟 <exe>.local 三個東西' -ForegroundColor Gray
Write-Host '   3. _Launch_with_Mesa.bat 不要直接從檔案總管雙擊,改用' -ForegroundColor Gray
Write-Host '      cmd /k 開 console 跑,看有沒有錯誤訊息' -ForegroundColor Gray
Write-Host ''
Write-Host ' 還原 (改回 NVIDIA driver,雖然你 partition 是死的):' -ForegroundColor White
Write-Host '   1. 刪除遊戲資料夾內的 opengl32.dll / libgallium_wgl.dll 等' -ForegroundColor Gray
Write-Host '   2. 刪除所有 .exe.local 檔' -ForegroundColor Gray
Write-Host '   3. 從 _MesaBackup\ 內恢復原本的 DLL (如果有)' -ForegroundColor Gray
Write-Host ''
