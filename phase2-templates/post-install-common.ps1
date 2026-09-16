<#
.SYNOPSIS
    Post-install fixups shared by every Windows template in this lab
    (ws2025-core-tmpl, win11-template, and whatever comes after).

.DESCRIPTION
    Proven twice by hand — once on the WS2025 Core template (VMID 9000,
    2026-09-01) and once on the Win11 template (VMID 9001, same night) — and
    written up here per this repo's own rule: a change made by hand isn't
    done until it's scripted and re-runnable. Every step checks current
    state before changing anything, so it's safe to re-run against a
    half-configured VM or a fresh one alike.

    Not wired to any transfer mechanism yet (no SCP/WinRM/file-share access
    into these VMs as of tonight — everything was typed by hand over an
    OpenSSH or console session). Until that exists, treat this as the
    authoritative reference for what to run and in what order, the same way
    phase1-network/opnsense/vlan-interfaces.md is the re-run record for
    hand-configured OPNsense changes. Run it locally on the guest, as
    Administrator.

.PARAMETER VirtioIsoDrive
    Drive letter the virtio-win ISO is mounted as (check with
    `Get-Volume | Where-Object DriveType -eq 'CD-ROM'` if unsure — Setup
    sometimes ejects the Windows install media automatically, leaving only
    this one, but the letter itself isn't guaranteed).

.PARAMETER OSDriverFolder
    The OS-version subfolder inside each virtio-win driver directory, e.g.
    'w11' for Windows 11 client or '2k25' for Server 2025. Differs per OS —
    this is the one real fork in an otherwise-identical sequence.

.PARAMETER TimeZoneId
    Defaults to Eastern, matching the owner's actual location and every
    template built so far.

.NOTES
    Deliberately NOT included here: the Network List Manager Policy fix
    (Unidentified Networks -> Private, via gpedit.msc) that makes the
    NetConnectionProfile survive sysprep generalization. That one needs
    either a verified registry path or LGPO.exe to script reliably, and
    neither was confirmed as of tonight — it stays a manual gpedit.msc step
    for now. See STATUS.md, 2026-09-01, for why this matters and what was
    tried.

    Also not included: BitLocker/Reserved Storage sysprep blockers. Those
    are one-time pre-sysprep checks, not routine post-install fixups, so
    they're handled inline in this file's sibling notes rather than here —
    see STATUS.md for the exact commands (Disable-BitLocker,
    DISM /Set-ReservedStorageState) if a future template hits them again.
#>
[CmdletBinding()]
param(
    [string]$VirtioIsoDrive = 'D',
    [Parameter(Mandatory)]
    [ValidateSet('w11', 'w10', '2k25', '2k22', '2k19')]
    [string]$OSDriverFolder,
    [string]$TimeZoneId = 'Eastern Standard Time'
)

$ErrorActionPreference = 'Stop'
$changed = $false

# --- 1. QEMU Guest Agent ------------------------------------------------
if (Get-Service -Name QEMU-GA -ErrorAction SilentlyContinue) {
    Write-Host "QEMU Guest Agent already installed — no change."
} else {
    $msi = "${VirtioIsoDrive}:\guest-agent\qemu-ga-x86_64.msi"
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /qn" -Wait
    Write-Host "QEMU Guest Agent installed."
    $changed = $true
}

# --- 2. Balloon driver service ------------------------------------------
# The driver itself binds via Plug and Play if it was loaded at Windows
# Setup's "Load driver" screen — this only registers the service binary,
# which doesn't self-register.
if (Get-Service -Name BalloonService -ErrorAction SilentlyContinue) {
    Write-Host "Balloon service already registered — no change."
} else {
    $blnsvr = "${VirtioIsoDrive}:\Balloon\$OSDriverFolder\amd64\blnsvr.exe"
    & $blnsvr -i
    Write-Host "Balloon service registered."
    $changed = $true
}

# --- 3. QEMU UTC-RTC fix -------------------------------------------------
# QEMU hands guests an RTC holding true UTC; Windows' default assumption is
# that the RTC holds local time. Without this, clock is off by the local
# UTC offset on every fresh boot.
$tzKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
if ((Get-ItemProperty -Path $tzKey -Name RealTimeIsUniversal -ErrorAction SilentlyContinue).RealTimeIsUniversal -eq 1) {
    Write-Host "RealTimeIsUniversal already set — no change."
} else {
    Set-ItemProperty -Path $tzKey -Name RealTimeIsUniversal -Value 1 -Type DWord
    Write-Host "RealTimeIsUniversal set."
    $changed = $true
}

if ((Get-TimeZone).Id -eq $TimeZoneId) {
    Write-Host "Timezone already $TimeZoneId — no change."
} else {
    Set-TimeZone -Id $TimeZoneId
    Write-Host "Timezone set to $TimeZoneId."
    $changed = $true
}

# --- 4. Disable IPv6 tunnel adapters ------------------------------------
# This lab is IPv4-only end to end (Kea is DHCPv4-only). Teredo/6to4/ISATAP
# have caused a sysprep generalize failure before (iphlpsvc.dll choking on
# tunnel-adapter cleanup) — disable proactively rather than reactively.
# NOTE: takes a reboot to fully take effect before sysprep; this script
# doesn't reboot for you.
foreach ($tunnel in 'teredo', '6to4', 'isatap') {
    $state = (netsh interface $tunnel show state | Select-String -Pattern 'disabled', 'State\s*:\s*disabled') 2>$null
    if ($state) {
        Write-Host "$tunnel already disabled — no change."
    } else {
        netsh interface $tunnel set state disabled | Out-Null
        Write-Host "$tunnel disabled."
        $changed = $true
    }
}

# --- 5. OpenSSH Server ----------------------------------------------------
$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
if ($cap.State -eq 'Installed') {
    Write-Host "OpenSSH.Server already installed — no change."
} else {
    Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    Write-Host "OpenSSH.Server installed."
    $changed = $true
}

$sshd = Get-Service -Name sshd
if ($sshd.StartType -ne 'Automatic') {
    Set-Service -Name sshd -StartupType Automatic
    Write-Host "sshd startup type set to Automatic."
    $changed = $true
}
if ($sshd.Status -ne 'Running') {
    Start-Service sshd
    Write-Host "sshd started."
    $changed = $true
}
if ($sshd.StartType -eq 'Automatic' -and $sshd.Status -eq 'Running') {
    Write-Host "sshd already Automatic/Running — no change." -ForegroundColor DarkGray
}

# --- 6. Network category ---------------------------------------------
# Only takes effect if the auto-created OpenSSH-Server-In-TCP firewall rule
# is to allow inbound at all (it's scoped to Private/Domain profiles only).
# This is the LIVE per-network setting, which does NOT survive sysprep
# generalization -- see the NOTES section at the top of this file for the
# durable (GPO-based) fix, which still has to be applied by hand.
$profile = Get-NetConnectionProfile
foreach ($p in $profile) {
    if ($p.NetworkCategory -eq 'Private') {
        Write-Host "$($p.InterfaceAlias) already Private — no change."
    } else {
        Set-NetConnectionProfile -InterfaceAlias $p.InterfaceAlias -NetworkCategory Private
        Write-Host "$($p.InterfaceAlias) set to Private."
        $changed = $true
    }
}

if (-not $changed) {
    Write-Host "`nNothing to do — already converged on the desired state." -ForegroundColor Green
} else {
    Write-Host "`nDone. Remaining manual steps before sysprep:" -ForegroundColor Yellow
    Write-Host " - Network List Manager Policy (gpedit.msc) if not already set"
    Write-Host " - Confirm Windows Update is fully caught up (blocks Reserved Storage otherwise)"
    Write-Host " - Reboot to lock in the disabled tunnel adapters"
    Write-Host " - Snapshot before sysprep"
}
