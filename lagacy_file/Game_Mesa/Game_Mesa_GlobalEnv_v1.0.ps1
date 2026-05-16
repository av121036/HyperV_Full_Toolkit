# =========================================================
#  Game_Mesa_GlobalEnv_v1.0.ps1
#
#  把 Mesa llvmpipe 4 個環境變數設成「系統全域」(Machine-level)。
#
#  為什麼需要這個:
#    NCSOFT 遊戲是 Purple.exe 啟動的,Purple 啟動完才 spawn LC.exe。
#    LC.exe 繼承 Purple 的環境變數,不是 cmd 的。Purple 是從檔案總管 /
#    開始功能表開的,完全不會有你 cmd 內的 set 變數。
#
#    解法:把 GALLIUM_DRIVER / MESA_* 設成「系統環境變數」-> 任何
#    process 開機後啟動都自動帶這些變數,包含 Purple、LC.exe。
#
#  注意:這些變數只對「有載入 Mesa opengl32.dll 的 process」生效。
#        系統其他 GUI 不會被影響(因為他們載 System32 那份 opengl32.dll)。
#
#  反向操作:
#    再跑此工具,選 [R] 即可全部移除。
# =========================================================

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

W-Title 'Mesa 系統環境變數設定 v1.0'

# =========================================================
#  預檢
# =========================================================
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole] 'Administrator')
if (-not $isAdmin) {
    W-Err '需要系統管理員權限 (要寫 Machine-level 環境變數)'
    exit 1
}

# =========================================================
#  要設的環境變數
# =========================================================
$vars = [ordered]@{
    'GALLIUM_DRIVER'              = 'llvmpipe'
    'MESA_LOADER_DRIVER_OVERRIDE' = 'llvmpipe'
    'LIBGL_ALWAYS_SOFTWARE'       = '1'
    'MESA_GL_VERSION_OVERRIDE'    = '4.5'
    'MESA_GLSL_VERSION_OVERRIDE'  = '450'
}

# =========================================================
#  顯示當前狀態
# =========================================================
W-Step '當前系統環境變數狀態:'
$anyExists = $false
foreach ($k in $vars.Keys) {
    $cur = [Environment]::GetEnvironmentVariable($k, 'Machine')
    if ($cur) {
        Write-Host ("  $k = $cur") -ForegroundColor Green
        $anyExists = $true
    } else {
        Write-Host ("  $k = (未設定)") -ForegroundColor DarkGray
    }
}

# =========================================================
#  選擇動作
# =========================================================
Write-Host ''
Write-Host '請選擇動作:' -ForegroundColor White
Write-Host '  [S] 設定 (Set) - 把 5 個 Mesa 變數寫進系統環境'
Write-Host '  [R] 移除 (Remove) - 從系統環境移除 5 個 Mesa 變數'
Write-Host '  [Q] 離開不做事'
Write-Host ''
$act = Read-Host '輸入'

# =========================================================
#  執行
# =========================================================
switch -Regex ($act) {
    '^[Ss]' {
        W-Step '寫入系統環境變數'
        foreach ($k in $vars.Keys) {
            $v = $vars[$k]
            [Environment]::SetEnvironmentVariable($k, $v, 'Machine')
            W-OK ("  $k = $v")
        }
        Write-Host ''
        W-Warn '已寫入。需要做以下其中一件事才會生效:'
        W-Info '  (A) 完整登出再登入 (推薦,影響範圍清楚)'
        W-Info '  (B) 重開 explorer.exe (對檔案總管雙擊啟動的程式有效)'
        W-Info '  (C) VM 整個重開 (最確定)'
        Write-Host ''
        W-Info '驗證方法:重啟後開 cmd,跑 set | findstr MESA'
        W-Info '應該看到 5 行 MESA / LIBGL / GALLIUM 變數'
    }
    '^[Rr]' {
        W-Step '從系統環境變數移除'
        foreach ($k in $vars.Keys) {
            [Environment]::SetEnvironmentVariable($k, $null, 'Machine')
            W-OK ("  已移除 $k")
        }
        Write-Host ''
        W-Warn '已移除。需要登出 / 重開 explorer / 重開 VM 才完全生效。'
    }
    default {
        W-Info '未選擇動作,離開'
        exit 0
    }
}

# =========================================================
#  附加:重啟 explorer 選項
# =========================================================
Write-Host ''
$rr = Read-Host '要立刻重開 explorer.exe 嗎?(會關閉所有檔案總管視窗,Y/N)'
if ($rr -match '^[Yy]') {
    W-Step '重啟 explorer.exe'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Start-Process explorer.exe
    }
    W-OK 'explorer 已重啟。現在開 Purple 應該會繼承新環境變數。'
}

Write-Host ''
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host ' 完成' -ForegroundColor Cyan
Write-Host ('=' * 60) -ForegroundColor Cyan
Write-Host ''
Write-Host '下一步:' -ForegroundColor White
Write-Host '  1. 開 Purple 啟動器' -ForegroundColor Gray
Write-Host '  2. 從 Purple 啟動天堂 Classic' -ForegroundColor Gray
Write-Host '  3. LC.exe 應該載入 Mesa opengl32.dll 而不是退回 GDI Generic' -ForegroundColor Gray
Write-Host '  4. 第一次 Mesa 編 shader 會頓 10~30 秒,正常' -ForegroundColor Gray
Write-Host ''
Write-Host '怎麼驗證 LC.exe 真的有用 Mesa:' -ForegroundColor White
Write-Host '  - 工作管理員 -> LC.exe -> 右鍵 -> 內容 -> 提供者' -ForegroundColor Gray
Write-Host '  - 或用 Process Explorer 看 LC.exe 載入的 opengl32.dll' -ForegroundColor Gray
Write-Host '    路徑應該是遊戲資料夾,不是 C:\Windows\System32' -ForegroundColor Gray
Write-Host ''
