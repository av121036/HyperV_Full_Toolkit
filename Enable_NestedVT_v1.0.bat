@echo off
REM ================================================================
REM  Enable_NestedVT_v1.0.bat
REM  Enable Hyper-V nested virtualization on one VM, so that
REM  LDPlayer / VirtualBox-based Android emulators can run inside it.
REM  Portable single file. ASCII only. Double-click to run.
REM  Notes:
REM   - Needs a Hyper-V host. Elevates itself via UAC.
REM   - AMD host: needs Windows 11 and VM config version 10.0+.
REM     (Windows 10 + AMD cannot do nested at all. Intel + Win10 OK.)
REM   - The VM must be OFF to change this setting; the script offers
REM     a graceful shutdown and asks before doing anything.
REM ================================================================
setlocal

net session >nul 2>&1
if %errorlevel%==0 goto :main
echo Requesting administrator rights (UAC popup)...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
exit /b

:main
echo.
echo === Hyper-V VMs on this computer ===
powershell -NoProfile -Command "Get-VM | Sort-Object Name | Format-Table Name, State, Version -AutoSize"
if errorlevel 1 goto :hvfail

set "VMNAME="
set /p VMNAME=Type the VM name to enable nested VT on:
if not defined VMNAME goto :novm

powershell -NoProfile -Command "$ErrorActionPreference='Stop'; $n='%VMNAME%'.Trim(); try { $vm=Get-VM -Name $n } catch { Write-Host ('VM not found: '+$n); exit 10 }; $amd=(Get-CimInstance Win32_Processor).Manufacturer -match 'AMD'; if($amd -and [version]$vm.Version -lt [version]'10.0'){ Write-Host ('ABORT: AMD host needs VM config version 10.0 or higher, this VM is '+$vm.Version+'. Nothing changed.'); exit 11 }; if((Get-VMProcessor -VMName $n).ExposeVirtualizationExtensions){ Write-Host 'Nested VT is ALREADY enabled on this VM. Nothing to do.'; exit 0 }; if($vm.State -ne 'Off'){ $a=Read-Host ('VM is '+$vm.State+'. Shut it down now, graceful? [Y/N]'); if($a -notmatch '^[Yy]'){ Write-Host 'Aborted by user. Nothing changed.'; exit 12 }; Stop-VM -Name $n -Force; $t=(Get-Date).AddSeconds(180); while((Get-VM -Name $n).State -ne 'Off' -and (Get-Date) -lt $t){ Start-Sleep -Seconds 3 }; if((Get-VM -Name $n).State -ne 'Off'){ Write-Host 'ABORT: shutdown timed out after 180s. Nothing changed.'; exit 13 } }; Set-VMProcessor -VMName $n -ExposeVirtualizationExtensions $true; if(-not (Get-VMProcessor -VMName $n).ExposeVirtualizationExtensions){ Write-Host 'FAILED: setting did not stick.'; exit 14 }; Write-Host ''; Write-Host ('OK: nested virtualization is now ENABLED on VM '+$n+'.'); $a=Read-Host 'Start the VM now? [Y/N]'; if($a -match '^[Yy]'){ Start-VM -Name $n; Write-Host ('VM state: '+(Get-VM -Name $n).State) }; Write-Host 'Check inside the VM: Task Manager - Performance - CPU - Virtualization: Enabled.'; exit 0"
if not %errorlevel%==0 echo Result: NOT completed (code %errorlevel%) - read the message above.
goto :end

:hvfail
echo.
echo ERROR: cannot list VMs. Is the Hyper-V feature installed on this computer?
goto :end

:novm
echo No VM name entered. Nothing changed.
goto :end

:end
echo.
pause
