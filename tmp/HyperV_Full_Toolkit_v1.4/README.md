# Hyper-V 完整工具包 v1.2

GPU-PV 直通 + 驅動複製 + 偽裝 + 共享 + 驗證。

## v1.2 更新

| 工具 | v1.2 改進 |
|---|---|
| **Host_Master.ps1** | 偵測 VM CPU 核心 < 4 自動詢問調整 |
| **Host_Share.ps1** | 自動設 NTFS Everyone 權限 + 關密碼保護共享 + 重啟 LanmanServer |
| **VM_Share_Connect.bat** | 純 ASCII,自動修 AllowInsecureGuestAuth / EnableLinkedConnections / 清舊 mapping,一鍵連通 |
| **VM_Camo.ps1** | 啟動時顯示目前 MAC OUI,提示挑對應品牌,不再對錯 |

## 目錄

```
HyperV_Full_Toolkit/
├── Host_Master.bat/ps1    GPU-PV 直通 + NVIDIA 驅動複製
├── Host_Share.bat/ps1     主機 SMB 共享建置
├── Host_Camo.bat/ps1      主機端偽裝 (MAC + BIOS GUID)
├── Host_Verify.bat/ps1    主機端狀態快照
├── VM_Camo.bat/ps1        VM 內偽裝 + 開機排程
├── VM_Verify.bat/ps1      VM 內狀態驗證
└── README.md
```

所有 `.ps1` 都有 UTF-8 BOM,Windows PowerShell 5.1 讀不會中文亂碼。

---

## 新 VM 完整建置流程(v1.2)

```
主機:
  1. Hyper-V 管理員建 Gen2 VM + 裝好 Win10
  2. Host_Master.bat   → GPU-PV + 驅動 + CPU 4 核
  3. Host_Share.bat    → 建立共享(只第一次需要)
  4. Host_Camo.bat     → 選品牌,例如 [2] GIGABYTE

VM(開機後):
  5. VM 裡看看 MAC 是什麼(VM_Camo 會自動顯示並建議)
  6. 檔案總管 \\<主機IP>\VM_Share → 複製 VM_Share_Connect.bat 到桌面
  7. 右鍵 VM_Share_Connect.bat 系統管理員執行 → 重開 VM
  8. VM_Camo.bat → 選 [2] GIGABYTE (跟 Host_Camo 對齊)
  9. 重開 VM

驗證:
  10. Host_Verify.bat 確認主機端
  11. VM_Verify.bat 確認 VM 端(注意 GPU / CPU 核心 / MAC 一致)
```

---

## 品牌對照(對齊用)

| 編號 | 品牌 | MAC OUI | 型號 |
|---|---|---|---|
| 1 | ASUS | 04-D4-C4 | ROG STRIX B660-A |
| 2 | GIGABYTE | 1C-1B-0D | B650 AORUS ELITE AX |
| 3 | MSI | 00-D8-61 | MAG B650 TOMAHAWK WIFI |
| 4 | ASRock | 70-85-C2 | B650 Steel Legend WiFi |
| 5 | Dell | 54-BF-64 | OptiPlex 7090 |

**v1.2 VM_Camo 會自動讀 MAC 顯示建議品牌**,不會再手滑選錯。

---

## 常見問題

**Q1. VM 裡看不到 RTX 4060,只有 AMD 內顯**
主機的 RTX 沒有接螢幕 → Hyper-V 不把它列為可分區 GPU。
解法:RTX 的 HDMI 孔插 dummy plug(蝦皮幾十塊)。

**Q2. VM_Share_Connect.bat 成功但檔案總管看不到 Z:**
`EnableLinkedConnections` 第一次設定要重開機才生效。
解法:bat 跑完後**重開 VM 一次**,就會出現。

**Q3. `net use Z:` 回「裝置名稱已在使用中」**
舊 mapping 卡住。新版 VM_Share_Connect.bat 已自動清理 Z:/Y: 才連。

**Q4. PowerShell 報「字串連結尾字元"'"」**
`.ps1` 檔 BOM 被剝掉了。驗證:
```powershell
Get-Content .\VM_Camo.ps1 -Encoding Byte -TotalCount 3 | % { '{0:X2}' -f $_ }
```
應該回 `EF / BB / BF`。不是就從 zip 重新解壓。

**Q5. VM 只給 2 核怎麼調到 4 核**
v1.2 Host_Master 會自動問。也可手動:
```powershell
Stop-VM -Name <VM名稱> -Force
Set-VMProcessor -VMName <VM名稱> -Count 4
Start-VM -Name <VM名稱>
```

---

## 不能改的(Hyper-V 硬傷)

`Win32_CS / Win32_BIOS / BaseBoard` 廠商永遠是 `Microsoft Corporation`,Hyper-V SMBIOS 寫死在韌體層,改不了。天堂經典版不會查 WMI 所以沒差。

`HypervisorPresent = True` 是 CPUID leaf,也改不了,只能關 Hyper-V Enlightenments 降低某些偵測機率。

---

## 版本紀錄

- **v1.0** — 初版 (Master + Camo + Verify)
- **v1.1** — 加入 Host_Share (SMB 共享)
- **v1.2** — 修 SMB 踩過的雷 + MAC 提示 + CPU 核心檢查
