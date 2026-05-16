@echo off
title Win11 GPU-PV - 512M / 4G (Super Multi-VM)
color 0B

>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo ===================================================
    echo [WARN] Admin required. Right-click - Run as administrator.
    echo ===================================================
    pause
    exit /b
)

echo ===================================================
echo   Win11 GPU-PV Multi-VM Mode  (512M / 4G)
echo ===================================================
echo.
echo   For: 8 ~ 12 VMs running at the same time
echo   Note: Some GPUs may reject 4GB HighMMIO.
echo         If Add-GPU fails, script will auto-revert to 1G/8G.
echo.

set /p vmName=">> VM name to attach GPU: "
if "%vmName%"=="" exit /b

echo.
echo [*] Stopping VM and applying 512M / 4G ...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Continue';" ^
  "$vm='%vmName%';" ^
  "Write-Host '--- Current state ---' -Fore Cyan;" ^
  "$v=Get-VM -Name $vm -ErrorAction SilentlyContinue;" ^
  "if (-not $v) { Write-Host ('[X] VM ' + $vm + ' not found!') -Fore Red; exit 1 };" ^
  "Write-Host ('Before: State=' + $v.State + ', LowMMIO=' + ($v.LowMemoryMappedIoSpace/1GB) + 'GB, HighMMIO=' + ($v.HighMemoryMappedIoSpace/1GB) + 'GB, GPU=' + (@(Get-VMGpuPartitionAdapter -VMName $vm).Count));" ^
  "Stop-VM -Name $vm -Force -ErrorAction SilentlyContinue;" ^
  "Get-VMGpuPartitionAdapter -VMName $vm -ErrorAction SilentlyContinue | ForEach-Object { Remove-VMGpuPartitionAdapter -VMName $vm -AdapterId $_.Id };" ^
  "try { Set-VM -Name $vm -GuestControlledCacheTypes $true -LowMemoryMappedIoSpace 512MB -HighMemoryMappedIoSpace 4GB -ErrorAction Stop; Write-Host '[OK] MMIO set to 512M/4G' -Fore Green } catch { Write-Host ('[X] Set-VM failed: ' + $_.Exception.Message) -Fore Red; exit 2 };" ^
  "try { Add-VMGpuPartitionAdapter -VMName $vm -ErrorAction Stop; Write-Host '[OK] GPU partition attached' -Fore Green } catch { Write-Host ('[X] Add-GPU FAILED: ' + $_.Exception.Message) -Fore Red; Write-Host '[*] Auto-reverting to 1G/8G ...' -Fore Yellow; Set-VM -Name $vm -LowMemoryMappedIoSpace 1GB -HighMemoryMappedIoSpace 8GB; try { Add-VMGpuPartitionAdapter -VMName $vm -ErrorAction Stop; Write-Host '[OK] Reverted to 1G/8G,GPU attached' -Fore Yellow } catch { Write-Host ('[X] Revert ALSO failed: ' + $_.Exception.Message) -Fore Red; exit 3 } };" ^
  "Write-Host '';" ^
  "Write-Host '--- Final state ---' -Fore Cyan;" ^
  "$v=Get-VM -Name $vm;" ^
  "$g=@(Get-VMGpuPartitionAdapter -VMName $vm).Count;" ^
  "Write-Host ('After: State=' + $v.State + ', LowMMIO=' + ($v.LowMemoryMappedIoSpace/1GB) + 'GB, HighMMIO=' + ($v.HighMemoryMappedIoSpace/1GB) + 'GB, GPU=' + $g) -Fore Cyan;" ^
  "if ($g -eq 1) { Write-Host '[OK] DONE' -Fore Green } else { Write-Host '[X] GPU partition missing!' -Fore Red; exit 4 }"

set "RC=%errorlevel%"
echo.
if "%RC%"=="0" (
    echo ===================================================
    echo [DONE] Configuration applied. You can start the VM.
    echo ===================================================
) else (
    echo ===================================================
    echo [FAILED] Exit code: %RC%
    echo   1 = VM not found
    echo   2 = Set-VM failed ^(MMIO settings rejected^)
    echo   3 = Both 512M/4G and 1G/8G failed to add GPU
    echo   4 = GPU partition missing after all attempts
    echo ===================================================
)
pause
exit /b %RC%
