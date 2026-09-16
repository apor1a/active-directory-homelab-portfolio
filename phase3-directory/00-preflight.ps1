<#
Run interactively on a freshly-cloned, not-yet-domain-joined VM (DC01, DC02,
or MS01) right after OOBE, before any promotion or domain-join script runs.

Bakes in three fixes discovered the hard way while building the WS2025 Core
template in Phase 2 (see STATUS.md, 2026-08-31/09-01 sessions), because a
linked clone inherits none of them automatically:

  - RealTimeIsUniversal: sysprep/generalization reset this on every clone
    even though the template had it set. Kerberos hard-fails on >5 min clock
    skew, so an unset value here can turn a DC promotion into a confusing
    failure that looks unrelated to time.
  - NetConnectionProfile: generalization also resets the network's identity
    fingerprint, so every clone re-detects as "Public" on first boot no
    matter what the template had. Public blocks inbound SSH via Windows
    Firewall's built-in OpenSSH-Server-In-TCP rule (Private/Domain only).
    The durable fix (a Local Security Policy baked into the template so this
    survives sysprep) is still open — see STATUS.md, Next action #2 — so
    this script applies the same manual per-clone workaround as a stopgap.
  - Static IP: these three hosts need stable addresses (a DNS server's own
    IP in particular can't float), so this takes them off Kea's CORP_SRV
    DHCP pool onto a fixed low-range address instead.

Does NOT attempt to fix the ~1 hour clock-skew bug from Phase 2 — its root
cause was never conclusively identified (STATUS.md, 2026-09-01). Instead
this prints the current UTC time so the operator can eyeball it against a
trusted clock and correct with Set-Date before promotion, rather than
trusting an automated "fix" for a bug nobody fully understands yet.

Static IP scheme (proposed this session, not yet used against a real host —
confirm before running): DC01 = 10.10.60.10, DC02 = 10.10.60.11,
MS01 = 10.10.60.12, leaving 10.10.60.100+ free for Kea's DHCP pool (the
range already seen in use by throwaway test hosts per STATUS.md).

Usage: run over an interactive SSH session, not a `ssh host 'powershell -c
...'` one-liner — later scripts in this sequence prompt for secrets, which
needs a real interactive shell to work.
#>
#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory)]
    [ValidateSet('DC01', 'DC02', 'MS01')]
    [string]$ComputerName,

    [Parameter(Mandatory)]
    [string]$IPAddress,

    [int]$PrefixLength = 24,
    [string]$DefaultGateway = '10.10.60.1',

    # DC01 has no domain to resolve against yet, so point it at FW01's
    # resolver (10.10.60.1) for now — 10-promote-dc01.ps1's -InstallDns
    # switches it to itself during promotion. DC02/MS01 should point
    # straight at DC01 (10.10.60.10) so they can resolve the domain before
    # joining it.
    [Parameter(Mandatory)]
    [string[]]$DnsServers
)

$ErrorActionPreference = 'Stop'

$adapters = @(Get-NetAdapter | Where-Object { $_.InterfaceDescription -like '*VirtIO*' -and $_.Status -eq 'Up' })
if ($adapters.Count -eq 0) {
    throw "No up VirtIO adapter found. Check the NIC is attached and vmbr1 trunking is intact."
}
if ($adapters.Count -gt 1) {
    throw "Multiple up VirtIO adapters found — these hosts are meant to be single-homed. Investigate before continuing."
}
$adapter = $adapters[0]

# --- 1. Static IP ---------------------------------------------------------
$existing = Get-NetIPAddress -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
if ($existing -and $existing.IPAddress -eq $IPAddress -and $existing.PrefixLength -eq $PrefixLength) {
    Write-Host "IP already set to $IPAddress/$PrefixLength — no change."
} else {
    $existing | Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $adapter.IfIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false
    New-NetIPAddress -InterfaceIndex $adapter.IfIndex -IPAddress $IPAddress -PrefixLength $PrefixLength -DefaultGateway $DefaultGateway | Out-Null
    Write-Host "Static IP set: $IPAddress/$PrefixLength via $DefaultGateway."
}

# --- 2. DNS client ---------------------------------------------------------
$currentDns = (Get-DnsClientServerAddress -InterfaceIndex $adapter.IfIndex -AddressFamily IPv4).ServerAddresses
if (($currentDns -join ',') -eq ($DnsServers -join ',')) {
    Write-Host "DNS servers already set to $($DnsServers -join ', ') — no change."
} else {
    Set-DnsClientServerAddress -InterfaceIndex $adapter.IfIndex -ServerAddresses $DnsServers
    Write-Host "DNS servers set to $($DnsServers -join ', ')."
}

# --- 3. Network category (stopgap — see header) -----------------------------
$netProfile = Get-NetConnectionProfile -InterfaceIndex $adapter.IfIndex
if ($netProfile.NetworkCategory -eq 'Private') {
    Write-Host "Network category already Private — no change."
} else {
    Set-NetConnectionProfile -InterfaceIndex $adapter.IfIndex -NetworkCategory Private
    Write-Host "Network category set to Private."
}

# --- 4. RealTimeIsUniversal -------------------------------------------------
$tzKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation'
$current = (Get-ItemProperty -Path $tzKey -Name RealTimeIsUniversal -ErrorAction SilentlyContinue).RealTimeIsUniversal
if ($current -eq 1) {
    Write-Host "RealTimeIsUniversal already set — no change."
} else {
    Set-ItemProperty -Path $tzKey -Name RealTimeIsUniversal -Value 1 -Type DWord
    Write-Host "RealTimeIsUniversal set to 1."
}

# --- 5. Clock sanity check (manual — see header) ----------------------------
Write-Host ''
Write-Host "Current UTC time on this host: $((Get-Date).ToUniversalTime())"
Write-Host 'Verify this against a trusted clock before continuing. The Phase 2'
Write-Host 'clock-skew bug (STATUS.md, 2026-09-01) was never root-caused, and'
Write-Host 'Kerberos will reject a DC promotion or domain join with >5 min skew.'
Write-Host 'Correct with Set-Date if needed.'
Write-Host ''

# --- 6. Rename (last — the only step here that needs a reboot) -------------
if ($env:COMPUTERNAME -eq $ComputerName) {
    Write-Host "Hostname already $ComputerName — no rename or reboot needed."
} else {
    Write-Host "Renaming $env:COMPUTERNAME to $ComputerName and rebooting..."
    Rename-Computer -NewName $ComputerName -Restart -Force
}
