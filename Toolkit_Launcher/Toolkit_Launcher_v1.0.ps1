# =========================================================
#  Toolkit_Launcher_v1.0.ps1
#
#  HyperV_Full_Toolkit-main 統一 GUI 啟動器。
#  把整個工具包的工作流程做成 GUI,主機端 + VM 內分頁式,
#  每一步一個按鈕,點下去就跑對應的 .bat,跑完自動標記完成 ✓
#
#  特色:
#    - Tab 1: 主機端流程 (Open_WindowsFeatures -> Open_AdvancedSharing
#                          -> Host_Master -> Host_Share -> Host_Camo)
#    - Tab 2: VM 內流程   (VM_Master -> VM_GPUWakeup -> VM_HostShortcut
#                          -> Mesa_OneClick)
#    - Tab 3: 診斷 / 工具 (VM_DiagUMD / VM_FixUMD / Defender / Show_IP)
#    - 完成狀態存到 Toolkit_Launcher_State.json,下次開啟自動顯示
#    - 環境偵測:看到 Hyper-V module 預設選主機 tab,否則 VM tab
# =========================================================

$ErrorActionPreference = 'Stop'
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# =========================================================
#  全域路徑
# =========================================================
$script:ToolkitRoot = Split-Path -Parent $PSScriptRoot   # 父資料夾 = HyperV_Full_Toolkit-main
if (-not (Test-Path (Join-Path $script:ToolkitRoot 'Host_Master_v1.7.bat'))) {
    # 萬一直接從 toolkit 根目錄跑,$PSScriptRoot 就是 root
    if (Test-Path (Join-Path $PSScriptRoot 'Host_Master_v1.7.bat')) {
        $script:ToolkitRoot = $PSScriptRoot
    }
}
$script:StateFile = Join-Path $PSScriptRoot 'Toolkit_Launcher_State.json'

# =========================================================
#  狀態載入 / 儲存
# =========================================================
function Load-State {
    if (Test-Path $script:StateFile) {
        try {
            return Get-Content $script:StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { }
    }
    return [PSCustomObject]@{ done = @{} }
}

function Save-State($state) {
    try {
        $state | ConvertTo-Json -Depth 5 | Set-Content $script:StateFile -Encoding UTF8 -Force
    } catch { }
}

$script:State = Load-State
if (-not $script:State.done) {
    $script:State | Add-Member -NotePropertyName done -NotePropertyValue (New-Object PSObject) -Force
}

function Mark-Done($id) {
    $script:State.done | Add-Member -NotePropertyName $id -NotePropertyValue ((Get-Date).ToString('s')) -Force
    Save-State $script:State
}

function Is-Done($id) {
    return ($null -ne $script:State.done.$id)
}

# =========================================================
#  環境偵測
# =========================================================
function Test-IsHyperVHost {
    try {
        $f = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop
        return $f.State -eq 'Enabled'
    } catch {
        return $false
    }
}

function Test-IsHyperVGuest {
    try {
        return (Test-Path 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters')
    } catch { return $false }
}

# =========================================================
#  Form
# =========================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = 'HyperV Toolkit Launcher v1.0'
$form.Size = New-Object System.Drawing.Size(820, 660)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 9)

# 頂部標題
$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'HyperV Full Toolkit - 統一啟動器'
$lblTitle.Location = New-Object System.Drawing.Point(15, 10)
$lblTitle.Size = New-Object System.Drawing.Size(780, 30)
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(40, 80, 140)
$form.Controls.Add($lblTitle)

$lblEnv = New-Object System.Windows.Forms.Label
$lblEnv.Location = New-Object System.Drawing.Point(15, 42)
$lblEnv.Size = New-Object System.Drawing.Size(780, 18)
$lblEnv.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblEnv)

# 偵測環境
$isHost  = Test-IsHyperVHost
$isGuest = Test-IsHyperVGuest
if ($isHost) {
    $lblEnv.Text = '偵測:主機端 (Hyper-V 已啟用)'
    $lblEnv.ForeColor = [System.Drawing.Color]::DarkGreen
} elseif ($isGuest) {
    $lblEnv.Text = '偵測:VM 內 (Hyper-V Guest)'
    $lblEnv.ForeColor = [System.Drawing.Color]::DarkBlue
} else {
    $lblEnv.Text = '偵測:一般 Windows (Hyper-V 未啟用)。可以從「主機端」分頁開始'
    $lblEnv.ForeColor = [System.Drawing.Color]::DarkOrange
}

# TabControl
$tab = New-Object System.Windows.Forms.TabControl
$tab.Location = New-Object System.Drawing.Point(15, 65)
$tab.Size = New-Object System.Drawing.Size(780, 500)
$tab.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 9)

$tabHost = New-Object System.Windows.Forms.TabPage
$tabHost.Text = '  主機端流程  '
$tab.TabPages.Add($tabHost)

$tabVM = New-Object System.Windows.Forms.TabPage
$tabVM.Text = '  VM 內流程  '
$tab.TabPages.Add($tabVM)

$tabDiag = New-Object System.Windows.Forms.TabPage
$tabDiag.Text = '  診斷 / 進階  '
$tab.TabPages.Add($tabDiag)

$form.Controls.Add($tab)

# =========================================================
#  Helper - 建一個 step row (✓ / 標題 / 描述 / 按鈕)
# =========================================================
function Add-Step {
    param(
        [System.Windows.Forms.TabPage]$Parent,
        [int]$Y,
        [string]$Id,
        [string]$Title,
        [string]$Desc,
        [string]$BatName,
        [string]$SubFolder = '',
        [string]$ButtonText = '執行',
        [scriptblock]$CustomAction = $null
    )

    # 完成標記
    $lblChk = New-Object System.Windows.Forms.Label
    $lblChk.Location = New-Object System.Drawing.Point(10, ($Y + 6))
    $lblChk.Size = New-Object System.Drawing.Size(25, 20)
    $lblChk.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 13, [System.Drawing.FontStyle]::Bold)
    if (Is-Done $Id) {
        $lblChk.Text = [char]0x2713  # ✓
        $lblChk.ForeColor = [System.Drawing.Color]::Green
    } else {
        $lblChk.Text = [char]0x25CB  # ○
        $lblChk.ForeColor = [System.Drawing.Color]::Gray
    }
    $Parent.Controls.Add($lblChk)

    # 標題
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = $Title
    $lblTitle.Location = New-Object System.Drawing.Point(40, $Y)
    $lblTitle.Size = New-Object System.Drawing.Size(520, 22)
    $lblTitle.Font = New-Object System.Drawing.Font('Microsoft JhengHei', 10, [System.Drawing.FontStyle]::Bold)
    $Parent.Controls.Add($lblTitle)

    # 描述
    $lblDesc = New-Object System.Windows.Forms.Label
    $lblDesc.Text = $Desc
    $lblDesc.Location = New-Object System.Drawing.Point(40, ($Y + 22))
    $lblDesc.Size = New-Object System.Drawing.Size(520, 32)
    $lblDesc.ForeColor = [System.Drawing.Color]::Gray
    $Parent.Controls.Add($lblDesc)

    # 把所有 closure 需要的東西複製到 local (GetNewClosure 不會抓 $script: scope)
    $capId       = $Id
    $capBatName  = $BatName
    $capSubFold  = $SubFolder
    $capAction   = $CustomAction
    $capRoot     = $script:ToolkitRoot
    $capStateFile = $script:StateFile
    $capState    = $script:State
    $capLblChk   = $lblChk

    # 按鈕
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = $ButtonText
    $btn.Location = New-Object System.Drawing.Point(580, ($Y + 8))
    $btn.Size = New-Object System.Drawing.Size(160, 36)
    $btn.Add_Click({
        $launchedOK = $false

        # 1. 跑 custom action (如果有)
        if ($capAction) {
            try {
                & $capAction
                $launchedOK = $true
            } catch {
                $detail = "Type: $($_.Exception.GetType().FullName)`r`nMessage: $($_.Exception.Message)`r`nLine: $($_.InvocationInfo.ScriptLineNumber)"
                [System.Windows.Forms.MessageBox]::Show("執行失敗 (custom action):`r`n$detail", '錯誤', 'OK', 'Error') | Out-Null
            }
        }
        # 2. 跑 .bat
        elseif ($capBatName) {
            if (-not $capRoot) {
                [System.Windows.Forms.MessageBox]::Show("Toolkit root 沒抓到 (內部錯誤)", '錯誤', 'OK', 'Error') | Out-Null
            } else {
                if ($capSubFold) {
                    $batPath = [System.IO.Path]::Combine($capRoot, $capSubFold, $capBatName)
                } else {
                    $batPath = [System.IO.Path]::Combine($capRoot, $capBatName)
                }

                if (-not [System.IO.File]::Exists($batPath)) {
                    [System.Windows.Forms.MessageBox]::Show("找不到檔案:`r`n$batPath", '錯誤', 'OK', 'Error') | Out-Null
                } else {
                    try {
                        $wd = [System.IO.Path]::GetDirectoryName($batPath)
                        # 直接執行 .bat,讓它開自己的 console 視窗,launcher 不等
                        # (Host_Master 之類要互動 + 跑很久,UI 不能 block)
                        $psi = New-Object System.Diagnostics.ProcessStartInfo
                        $psi.FileName = $batPath
                        $psi.WorkingDirectory = $wd
                        $psi.UseShellExecute = $true
                        [System.Diagnostics.Process]::Start($psi) | Out-Null
                        # 不 WaitForExit,launcher 立刻釋放 UI
                        # 立刻標記完成 (假設使用者點下去 = 打算跑完)
                        $launchedOK = $true
                    } catch {
                        $detail = "Type: $($_.Exception.GetType().FullName)`r`nMessage: $($_.Exception.Message)`r`nLine: $($_.InvocationInfo.ScriptLineNumber)`r`nBatPath: $batPath"
                        [System.Windows.Forms.MessageBox]::Show("啟動失敗:`r`n$detail", '錯誤', 'OK', 'Error') | Out-Null
                    }
                }
            }
        }

        # 3. 成功的話標記 done
        if ($launchedOK) {
            try {
                $capLblChk.Text = [char]0x2713
                $capLblChk.ForeColor = [System.Drawing.Color]::Green
                if ($null -eq $capState.done) {
                    $capState | Add-Member -MemberType NoteProperty -Name done -Value (New-Object PSObject) -Force
                }
                $capState.done | Add-Member -MemberType NoteProperty -Name $capId -Value ((Get-Date).ToString('s')) -Force
                $json = $capState | ConvertTo-Json -Depth 5
                [System.IO.File]::WriteAllText($capStateFile, $json, [System.Text.Encoding]::UTF8)
            } catch {
                # 標記失敗不影響使用者
            }
        }
    }.GetNewClosure())
    $Parent.Controls.Add($btn)

    # 分隔線
    $sep = New-Object System.Windows.Forms.Label
    $sep.BorderStyle = 'Fixed3D'
    $sep.AutoSize = $false
    $sep.Height = 2
    $sep.Width = 730
    $sep.Location = New-Object System.Drawing.Point(15, ($Y + 62))
    $Parent.Controls.Add($sep)
}

# =========================================================
#  Tab 1: 主機端流程
# =========================================================
$y = 15

Add-Step -Parent $tabHost -Y $y -Id 'host_winfeat' `
    -Title '1. 啟用 Windows 功能 (Hyper-V / 平台)' `
    -Desc "勾選: Hyper-V / 虛擬機器平台 / 受監督管理程式平台`r`n勾完按確定,可能要重開機" `
    -BatName 'Open_WindowsFeatures.bat' `
    -ButtonText '開啟 Windows 功能'
$y += 70

Add-Step -Parent $tabHost -Y $y -Id 'host_enablehv' `
    -Title '1b. 強制啟用 Hyper-V (如果上面找不到選項)' `
    -Desc 'DISM 直接啟用,適用某些版本沒在 Windows 功能列出 Hyper-V 的情況' `
    -BatName 'EnableHyperV.bat' `
    -ButtonText '強制啟用 Hyper-V'
$y += 70

Add-Step -Parent $tabHost -Y $y -Id 'host_share_setting' `
    -Title '2. 進階共用設定 (公用共用開、密碼保護關)' `
    -Desc 'VM 才能匿名連到主機 share。會跳出進階共用設定視窗' `
    -BatName 'Open_AdvancedSharing.bat' `
    -ButtonText '開啟進階共用'
$y += 70

Add-Step -Parent $tabHost -Y $y -Id 'host_master' `
    -Title '3. 主機 GPU 直通 + driver 複製到 VM' `
    -Desc '建 GPU partition,把 NVIDIA driver 整包推進指定 VM' `
    -BatName 'Host_Master_v1.7.bat' `
    -ButtonText 'Host_Master_v1.7'
$y += 70

Add-Step -Parent $tabHost -Y $y -Id 'host_share' `
    -Title '4. 主機共用資料夾 (share_folder)' `
    -Desc '建 Desktop\share_folder + SMB 共用 + 寫 VM_Share_Connect.bat 進去' `
    -BatName 'Host_Share_v1.5.bat' `
    -ButtonText 'Host_Share_v1.5'
$y += 70

Add-Step -Parent $tabHost -Y $y -Id 'host_camo' `
    -Title '5. 主機偽裝 (選擇性)' `
    -Desc '改主機名 / SMBIOS / MAC 等,反偵測用' `
    -BatName 'Host_Camo_v1.2.bat' `
    -ButtonText 'Host_Camo_v1.2'

# =========================================================
#  Tab 2: VM 內流程
# =========================================================
$y = 15

Add-Step -Parent $tabVM -Y $y -Id 'vm_master' `
    -Title '1. VM 內基本設定 (在 VM 裡跑)' `
    -Desc '關 Defender、調 UAC、改電源設定、自動登入 等' `
    -BatName 'VM_Master_v1.0.bat' `
    -ButtonText 'VM_Master_v1.0'
$y += 70

Add-Step -Parent $tabVM -Y $y -Id 'vm_gpuwakeup' `
    -Title '2. GPU 喚醒排程 (在 VM 裡跑)' `
    -Desc '註冊 AtStartup 排程,開機自動 wake up NVIDIA partition + self-heal registry' `
    -BatName 'VM_GPUWakeup_v1.0.bat' `
    -ButtonText 'VM_GPUWakeup'
$y += 70

Add-Step -Parent $tabVM -Y $y -Id 'vm_hostshortcut' `
    -Title '3. 主機共用桌面捷徑 (在 VM 裡跑,免進檔案總管打 IP)' `
    -Desc "★ 新工具:Hyper-V KVP 自動讀主機名 + 寫 SMB 認證 + 建桌面捷徑`r`n取代「進檔案總管 -> 輸入 \\HostIP -> 拖到桌面」流程" `
    -BatName 'VM_HostShortcut_v1.0.bat' `
    -SubFolder 'VM_HostShortcut' `
    -ButtonText 'VM_HostShortcut'
$y += 70

Add-Step -Parent $tabVM -Y $y -Id 'vm_mesa' `
    -Title '4. Mesa 軟體 OpenGL (GPU partition 死掉時用)' `
    -Desc 'GUI 一鍵下載 + 部署 Mesa + 設環境變數。Win10 + Blackwell GPU 必跑(v1.1 會自動處理 Defender)' `
    -BatName 'Mesa_OneClick_v1.1.bat' `
    -SubFolder 'Mesa_OneClick' `
    -ButtonText 'Mesa_OneClick'
$y += 70

# 額外: VM_Create 雖然算主機端但邏輯上是「開新 VM」
Add-Step -Parent $tabVM -Y $y -Id 'vm_create' `
    -Title '0. 建新 VM (在主機跑,先有 VM 再做上面 1~4)' `
    -Desc '從 ISO + VHDX 範本建一台新的 Gen2 VM (自動配置 CPU/RAM/網路/checkpoint)' `
    -BatName 'VM_Create_v1.0.bat' `
    -ButtonText 'VM_Create_v1.0'

# =========================================================
#  Tab 3: 診斷 / 進階
# =========================================================
$y = 15

Add-Step -Parent $tabDiag -Y $y -Id 'tool_showip' `
    -Title 'Show_IP - 顯示主機 IP / 介面卡資訊' `
    -Desc '查當前主機的 IP,給 VM 連線用' `
    -BatName 'Show_IP.bat' `
    -ButtonText 'Show_IP'
$y += 70

Add-Step -Parent $tabDiag -Y $y -Id 'tool_defender' `
    -Title 'Defender_Manager - 管理 Windows Defender' `
    -Desc '主機 Defender 控制' `
    -BatName 'Defender_Manager.bat' `
    -ButtonText 'Defender_Manager'
$y += 70

Add-Step -Parent $tabDiag -Y $y -Id 'tool_gpu_passthrough' `
    -Title '實體機顯卡直通 w11 (進階)' `
    -Desc '主機本身就是 Win11 的場景,FIXED 版' `
    -BatName '2_實體機顯卡直通w11_FIXED.bat' `
    -ButtonText '實體機顯卡直通'
$y += 70

Add-Step -Parent $tabDiag -Y $y -Id 'diag_umd' `
    -Title 'VM_DiagUMD - 列 partition UMD registry 路徑' `
    -Desc '在 VM 內跑,診斷 D3D / OpenGL 路徑指向是否正確' `
    -BatName 'VM_DiagUMD_v1.0.bat' `
    -SubFolder 'VM_DiagUMD' `
    -ButtonText 'VM_DiagUMD'
$y += 70

Add-Step -Parent $tabDiag -Y $y -Id 'diag_fixumd' `
    -Title 'VM_FixUMD - 補寫 D3D10/11/12 UMD 欄位' `
    -Desc '在 VM 內跑,把缺的 UserModeDriverNameX / D3DUMDFileName / DXCoreDriverName 補齊' `
    -BatName 'VM_FixUMD_v1.0.bat' `
    -SubFolder 'VM_DiagUMD' `
    -ButtonText 'VM_FixUMD'
$y += 70

Add-Step -Parent $tabDiag -Y $y -Id 'diag_deep' `
    -Title 'VM_DiagDeep - 全面診斷 (OS/VBS/HVCI/事件記錄/dxdiag)' `
    -Desc '在 VM 內跑,partition 死掉時用,輸出貼出來協助判斷' `
    -BatName 'VM_DiagDeep_v1.0.bat' `
    -SubFolder 'VM_DiagUMD' `
    -ButtonText 'VM_DiagDeep'
$y += 70

Add-Step -Parent $tabDiag -Y $y -Id 'diag_svc' `
    -Title 'VM_DiagSvc - VirtualRender service / vrd.sys 檢查' `
    -Desc '在 VM 內跑,看 partition KMD 是否正常載入' `
    -BatName 'VM_DiagSvc_v1.0.bat' `
    -SubFolder 'VM_DiagUMD' `
    -ButtonText 'VM_DiagSvc'

# =========================================================
#  底部按鈕
# =========================================================
$btnReset = New-Object System.Windows.Forms.Button
$btnReset.Text = '重置完成狀態'
$btnReset.Location = New-Object System.Drawing.Point(15, 575)
$btnReset.Size = New-Object System.Drawing.Size(110, 28)
$btnReset.Add_Click({
    $ans = [System.Windows.Forms.MessageBox]::Show('確定要清除所有「已完成」標記?', '確認', 'YesNo', 'Question')
    if ($ans -eq 'Yes') {
        $script:State = [PSCustomObject]@{ done = New-Object PSObject }
        Save-State $script:State
        [System.Windows.Forms.MessageBox]::Show('已重置。下次重開此工具會看到全部 ○', '完成', 'OK', 'Information') | Out-Null
    }
})
$form.Controls.Add($btnReset)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Text = '提示:每個步驟按鈕跑完會自動標 ✓。下次再開工具會記得你做到哪'
$lblHint.Location = New-Object System.Drawing.Point(140, 580)
$lblHint.Size = New-Object System.Drawing.Size(540, 20)
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblHint)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = '關閉'
$btnClose.Location = New-Object System.Drawing.Point(720, 575)
$btnClose.Size = New-Object System.Drawing.Size(75, 28)
$btnClose.Add_Click({ $form.Close() })
$form.Controls.Add($btnClose)

# 預設選 tab
if ($isHost -and -not $isGuest) {
    $tab.SelectedIndex = 0
} elseif ($isGuest) {
    $tab.SelectedIndex = 1
} else {
    $tab.SelectedIndex = 0
}

[void]$form.ShowDialog()
