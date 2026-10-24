VM_FileSync v1.0 — 把主機資料夾同步進 Hyper-V VM
================================================================
建立日期:2026-08-04    本機:DESKTOP-HT3G2M0(Win11 build 26200)

檔案
----
VM_FileSync_v1.0.ps1        核心引擎(可單獨用命令列跑)
VM_FileSync_GUI_v1.0.ps1    圖形介面
VM_FileSync_v1.0.bat        啟動器(自動提權,雙擊這個)
VM_FileSync_README.txt      本檔


它解決什麼問題
--------------
把桌面的 share 資料夾同步進 VM 裡指定的資料夾,**VM 開機或關機都能用**;
並且在 VM 內加上 Windows Defender 排除資料夾,避免同步進去的檔案被砍掉。


三條路線(工具依 VM 狀態與有沒有帳密自動選)
--------------------------------------------
VM 關機            → 掛載 VHDX + robocopy
                     免帳密、支援增量(只傳有變的檔)、可設 Defender 排除。最完整。

VM 開機 + 有帳密   → PowerShell Direct(走 VMBus,不經網路)
                     支援遞迴、可順便設 Defender 排除。

VM 開機 + 沒帳密   → Copy-VMFile ★ 免帳密
                     只需要主機端的「客體服務介面」整合服務,工具會自動幫你啟用。
                     ⚠ 限制:只能推不能拉、無法在 VM 內執行指令(所以設不了 Defender
                     排除)、沒有增量比對(每次整包重傳)。

★ 空密碼帳號只能走 Copy-VMFile。Windows 預設把空密碼限制成「只能從主控台登入」,
  PowerShell Direct 一律回「認證無效」——本機 VM 4(帳號 admin、無密碼)實測確認。


大量資料反覆同步:改走 SMB 從 VM 內拉
--------------------------------------
Copy-VMFile 每次都整包重傳,share_folder 有 3.3 GB 的話很浪費。
主機這邊 SMB 共享「已經存在」(Host_Share v1.5 建的):

  共享名稱  share_folder  ->  C:\Users\User\Desktop\share_folder
  主機在虛擬交換器上的 IP:172.19.208.1(vEthernet (Default Switch))
  其他既有共享:Gamania / MapleStory / Users / VMShare

在 VM 內執行一次(之後開機自動接上):

  net use Z: \\172.19.208.1\share_folder /persistent:yes

之後在 VM 內做增量同步:

  robocopy Z:\ C:\VMShare /E /R:1 /W:2 /MT:16 /XJ

優點:速度最快、支援增量。缺點:VM 內會留下網路磁碟機痕跡(對反偵測 VM 是額外曝光面),
而且第一次要在 VM 內手動跑一次。純推送少量檔案就用 Copy-VMFile,不必碰 SMB。


安全防呆(關機路線)
--------------------
下列情況一律擋下不動手,因為離線寫入有讓虛擬硬碟報廢的風險:
  * VM 有檢查點          → 差異磁碟鏈被寫壞就整條救不回來
  * 虛擬硬碟是差異磁碟   → 同上
  * VM 是「已儲存」狀態  → 記憶體狀態會在開機時蓋掉離線改動
  * VM 掛了多顆硬碟      → 無法自動判斷哪顆是系統碟
  * VHDX 已被掛載佔用    → Attached=True

2026-08-04 盤點:本機 1~6 號 VM 全部零檢查點、單顆 Dynamic 磁碟,關機路線可用。
註:VM「1」的磁碟是 D:\Hyperdisk\7.vhdx(不是 1.vhdx)。工具一律從
    Get-VMHardDiskDrive 讀實際路徑,不靠檔名猜。


Defender 排除是怎麼做的(重要,有個非顯而易見的機制)
------------------------------------------------------
要防的 Defender 有「兩個」:

1. 主機的 Defender
   VHDX 掛載後在主機上就是一顆普通磁碟機,主機的即時保護會掃進去、會隔離檔案。
   工具會在複製「之前」動態加主機排除,複製完自動移除(只移除自己加的那筆)。

2. VM 內的 Defender
   VM 開機中 → PowerShell Direct 下 Add-MpPreference,立即生效。
   VM 關機中 → 寫群組原則檔 Registry.pol 進離線 VHDX,
               VM「下次開機」時由群組原則用戶端套用生效。

   ⚠ 為什麼關機時不直接改 SOFTWARE 登錄檔 hive?
     因為這台機器的 RegLoadKey 被系統層擋住:一律回 err=87(參數錯誤),
     reg.exe load 也全滅,而 reg save 正常。檔案放 C:\ 根目錄、Windows\Temp、
     使用者 Temp 都一樣;SeRestorePrivilege / SeBackupPrivilege 都確認 enable 成功。
     2026-08-04 用 P/Invoke 直接呼叫 API 驗證過,不是 reg.exe 的用法問題。
     Registry.pol 是繞過這個限制的路,而且它落在「原則」分支,
     不受 VM 內竄改防護(Tamper Protection)影響。

   寫入紀律:只「附加」條目,絕不覆寫既有內容。VM 若已有本機原則,
   會先備份成 Registry.pol.bak-<時間戳> 再附加。gpt.ini 同樣先備份再改版本號。


用法
----
雙擊 VM_FileSync_v1.0.bat(會自動要求提權)。

命令列(要以系統管理員身分執行):
  # 先看六台 VM 現況與可否同步,不動任何東西
  .\VM_FileSync_v1.0.ps1 -ListOnly

  # 乾跑,只印會做什麼
  .\VM_FileSync_v1.0.ps1 -VMName 4 -Dest 'C:\VMShare' -AddExclusion -DryRun

  # 實際同步到多台
  .\VM_FileSync_v1.0.ps1 -VMName 2,3,4 -Source 'C:\Users\User\Desktop\share_folder' `
                         -Dest 'C:\VMShare' -AddExclusion

參數
  -Source           來源資料夾,預設 <使用者>\Desktop\share_folder
  -VMName           目標 VM,可多台
  -Dest             VM 內的目的路徑,預設 C:\VMShare(關機路線只支援 C: 磁碟)
  -AddExclusion     在 VM 內加 Defender 排除資料夾
  -Mirror           鏡像模式,會刪除目的端多餘檔案。預設不開,危險。
  -DryRun           乾跑
  -ListOnly         只盤點
  -GuestCredential  VM 內帳密(開機路線需要)


已驗證 / 未驗證
----------------
已實機驗證(2026-08-04,VM 4,關機路線):
  * 掛載 → 建資料夾 → robocopy → 卸載,全鏈成功,exit 0
  * 首次複製與增量複製都正確(重新掛載獨立驗證檔案內容與子目錄結構)
  * 主機排除加了又乾淨移除,清單回到原本 5 筆
  * Registry.pol 產生正確(PReg 標頭、條目解碼相符)、gpt.ini 版本 65536
  * 零殘留:VHDX Attached=False、無殘留登錄檔 hive

GUI 已驗證(2026-08-04):
  * 零語法錯誤、UTF-8 BOM 正確、引擎未被改動
  * headless 自我測試(-SelfTest)提權與非提權都通過;提權下正確列出 6 台 VM
    的狀態與路線判定,證明 GUI → 引擎 → Hyper-V 整條接線通了
  * 非提權時正確顯示警告並停用「開始同步」鈕,不會炸窗

開機路線已實機驗證(2026-08-04,VM 4 開機狀態,零帳密):
  * 自動偵測 Running → 自動啟用客體服務介面 → Copy-VMFile 逐檔推送
  * 4 個檔案(含子目錄)全部成功,耗時 0.3 秒,exit 0
  * 乾跑模式正確預告會走哪條路線、會推幾個檔

尚未驗證:
  * Registry.pol 寫進去後,VM 開機時 Defender「真的」吃到這條排除
    —— 需要在 VM 內跑 (Get-MpPreference).ExclusionPath 確認一次。
       主機這邊無法代勞:RegLoadKey 被擋(讀不到 VM 登錄檔),
       Copy-VMFile 又只能推不能拉、不能在 VM 內執行指令。
  * PowerShell Direct 路線(本機 VM 帳號無密碼,走不了這條)
  * SMB 從 VM 內拉的流程(共享已存在,但沒在 VM 內實跑過 net use)
  * GUI 視窗的實際外觀與操作手感(需使用者開一次過目)
  * 安全防呆未用「注入法」反向驗證(不想在使用者的 VM 上建/刪檢查點來測)


踩過的坑(給之後改這支工具的人)
--------------------------------
1. 含中文的 .ps1 一定要 UTF-8 with BOM,否則 PowerShell 5.1 當 cp950 解析、整檔炸掉。
2. .bat 的「內容」一律純 ASCII(檔名可以中文)。
3. PowerShell 的陣列 splatting 是「位置繫結」,-Source 之類的字串會被當成值。
   本工具的 param 有 PositionalBinding=$false,漏打參數名會直接報錯,
   不會像先前那樣讓路徑位移到 -GuestCredential 上、跳出認證對話框卡住流程。
4. 不要用單字母函式名。PowerShell 別名優先權高於函式,R 是 Invoke-History。
5. PS 5.1 的 '*>' 檔案重導向寫出 UTF-16,中文 log 會變亂碼;用 Out-File -Encoding utf8。
6. 對原生 exe 用 2>&1,stderr 會被包成 ErrorRecord,配 EAP=Stop 會把 exit 0 誤判成失敗。
   引擎裡的 Invoke-Native 就是為此存在。
