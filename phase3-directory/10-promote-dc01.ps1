<#
Promotes this host to DC01 — first domain controller, new forest
ad.bluegillbass.lab (BLUEBASS). Run 00-preflight.ps1 for DC01 first and
confirm the reboot completed with the new hostname before this.

SafeModeAdministratorPassword (the DSRM password) is prompted interactively
by default — the idiomatic choice, since a plaintext password passed as a
script argument or left sitting in an environment variable is visible to
anything that can read this process's environment or command line, which on
a domain controller is a real thing to avoid. Set $env:DSRM_PASSWORD first
(matches secrets/lab-credentials.env's DSRM_PASSWORD field) only if you need
a non-interactive re-run — e.g. testing this script's idempotency — and
accept that tradeoff knowingly.

Worth knowing for afterward: Install-ADDSForest does NOT set the domain
Administrator account's password. BLUEBASS\Administrator inherits whatever
the local Administrator password already was on this box before promotion
(set back at Windows Setup/OOBE) — not anything from
secrets/lab-credentials.env. That's the account and password you'll
actually log into afterward.

ForestMode/DomainMode pinned to the "2016" functional level per the design
doc (Section 6) — deliberately not the highest level Server 2025 offers, to
leave room to test older-behavior scenarios later. The PowerShell enum value
for this is 'WinThreshold', not 'Win2016' — Server 2016 shipped under the
internal codename "Threshold", and the enum was never renamed to match the
marketing version. Confirmed by trial: Install-ADDSForest -ForestMode's
error message lists the full valid set (Win2008, Win2008R2, Win2012,
Win2012R2, WinThreshold, Win2025, Default) — there is no Win2016 or Win2019
at all.
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

if (Test-Path 'C:\Windows\NTDS\ntds.dit') {
    Write-Host 'AD database (ntds.dit) already exists — this host is already a domain controller. Nothing to do.'
    exit 0
}

if ($env:DSRM_PASSWORD) {
    $dsrmPassword = ConvertTo-SecureString $env:DSRM_PASSWORD -AsPlainText -Force
} else {
    $dsrmPassword = Read-Host -AsSecureString -Prompt 'DSRM (Directory Services Restore Mode) password for DC01'
}

Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools

Install-ADDSForest `
    -DomainName 'ad.bluegillbass.lab' `
    -DomainNetbiosName 'BLUEBASS' `
    -ForestMode 'WinThreshold' `
    -DomainMode 'WinThreshold' `
    -SafeModeAdministratorPassword $dsrmPassword `
    -InstallDns `
    -Force
