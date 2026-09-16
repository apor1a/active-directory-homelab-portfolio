<#
Bulk-imports data/staff.csv into department OUs and department groups. Run
after 20-ou-structure.ps1 and 30-groups.ps1.

Deliberately does NOT follow the design doc's Section 6 example literally —
that example reads a per-user Password column straight out of the CSV.
staff.csv is tracked in git (synthetic data, meant to be committed), so a
password column there would mean plaintext lab credentials sitting in
version-control history forever — exactly what CLAUDE.md's "never commit
secrets" rule exists to prevent. Instead every synthetic account gets the
same password, sourced the same way as the DSRM password in
10-promote-dc01.ps1: $env:DEFAULT_USER_PASSWORD if set (matches
secrets/lab-credentials.env), otherwise an interactive prompt.

ChangePasswordAtLogon is left off on purpose — these are throwaway
synthetic identities for generating domain activity, not real onboarding,
and forcing a first-logon change would just break any later exercise that
logs into an account non-interactively.

-Path resolves per-user from the CSV's Dept column, so it depends on those
values matching the OU names 20-ou-structure.ps1 created exactly, including
case (same caveat the design doc's own example calls out).
#>
#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory

$ErrorActionPreference = 'Stop'
$Base = 'DC=ad,DC=bluegillbass,DC=lab'
$CsvPath = Join-Path $PSScriptRoot 'data\staff.csv'

if ($env:DEFAULT_USER_PASSWORD) {
    $password = ConvertTo-SecureString $env:DEFAULT_USER_PASSWORD -AsPlainText -Force
} else {
    $password = Read-Host -AsSecureString -Prompt 'Default password for all imported synthetic users'
}

Import-Csv $CsvPath | ForEach-Object {
    $sam = $_.Sam
    $groupName = "SG-$($_.Dept)"

    if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
        Write-Host "$sam already exists — no change."
    } else {
        New-ADUser `
            -Name "$($_.First) $($_.Last)" `
            -SamAccountName $sam `
            -UserPrincipalName "$sam@ad.bluegillbass.lab" `
            -GivenName $_.First `
            -Surname $_.Last `
            -Department $_.Dept `
            -Title $_.Title `
            -Path "OU=$($_.Dept),OU=Users,OU=Corp,$Base" `
            -AccountPassword $password `
            -ChangePasswordAtLogon $false `
            -Enabled $true
        Write-Host "Created $sam ($($_.Dept))."
    }

    # Checked independently of user creation above: if a prior run created the
    # user but failed before this Add-ADGroupMember call (transient AD error,
    # a group not yet replicated), the user-exists check alone would skip this
    # step forever on every re-run and silently leave the account groupless.
    if (Get-ADGroupMember -Identity $groupName -ErrorAction SilentlyContinue | Where-Object SamAccountName -eq $sam) {
        Write-Host "$sam already in $groupName — no change."
    } else {
        Add-ADGroupMember -Identity $groupName -Members $sam
        Write-Host "Added $sam to $groupName."
    }
}
