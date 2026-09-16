<#
Promotes this host to DC02 — second, replica domain controller for the
existing ad.bluegillbass.lab forest. Run 00-preflight.ps1 for DC02 first
(point its DNS servers at DC01, 10.10.60.10 — not FW01 — since DC02 needs to
resolve the domain before it can join it).

Two ways to get from a fresh VM to a promoted replica DC, and this uses the
second:
  - Domain-join first (Add-Computer), then promote
    (Install-ADDSDomainController) as two separate steps — the traditional
    order, and how 17-join-ms01.ps1 handles MS01 since a member server has
    no promotion step to fold the join into.
  - Let Install-ADDSDomainController do both in one command, given a domain
    admin credential — what this script does. It's the more idiomatic modern
    approach for a DC specifically: fewer reboots, and the join can't
    silently drift from the promotion since there's only one command to get
    wrong.

Prompts for a domain admin credential via Get-Credential — there's no
less-secure env-var shortcut offered here on purpose, unlike the DSRM and
default-user-password prompts elsewhere in this phase, since a full
username+password credential pair doesn't fit cleanly into a single
secrets/lab-credentials.env value the way a lone password does.
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
    $dsrmPassword = Read-Host -AsSecureString -Prompt 'DSRM (Directory Services Restore Mode) password for DC02'
}

$cred = Get-Credential -Message 'Domain admin credential (e.g. BLUEBASS\Administrator) to join and promote DC02'

Install-WindowsFeature AD-Domain-Services, DNS -IncludeManagementTools

Install-ADDSDomainController `
    -DomainName 'ad.bluegillbass.lab' `
    -Credential $cred `
    -SafeModeAdministratorPassword $dsrmPassword `
    -InstallDns `
    -Force
