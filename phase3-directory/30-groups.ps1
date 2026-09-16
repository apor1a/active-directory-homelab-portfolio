<#
Creates the department security groups — one per OU=Users sub-OU, so GPOs
and fine-grained password policies that need to target a group rather than
an OU have something to attach to (design doc, Section 4: PSOs apply to
groups, not OUs) — plus one example role group, SG-FileServer-RW, named
explicitly in the design doc for MS01's eventual file share.

Run after 20-ou-structure.ps1 — OU=Groups must exist first.
#>
#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory

$ErrorActionPreference = 'Stop'
$Base = 'DC=ad,DC=bluegillbass,DC=lab'
$GroupsOU = "OU=Groups,OU=Corp,$Base"

function New-GroupIfMissing {
    param([string]$Name, [string]$Description)
    if (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue) {
        Write-Host "$Name already exists — no change."
    } else {
        New-ADGroup -Name $Name -GroupCategory Security -GroupScope Global -Path $GroupsOU -Description $Description
        Write-Host "Created $Name."
    }
}

'Legal', 'Finance', 'HR', 'IT', 'Records' | ForEach-Object {
    New-GroupIfMissing -Name "SG-$_" -Description "Members of the $_ department"
}

New-GroupIfMissing -Name 'SG-FileServer-RW' -Description 'Read/write access to the MS01 file share'
