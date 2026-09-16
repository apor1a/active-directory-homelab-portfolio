<#
Domain-joins MS01 as a member server — no AD DS role here, just
Add-Computer. If the OU structure already exists (20-ou-structure.ps1 has
run), also moves MS01's computer object into OU=Servers,OU=Corp; otherwise
Add-Computer drops it in the default Computers container and this script
says so, since it can't move something into an OU that doesn't exist yet.
Safe to re-run later purely to pick up that move once 20-ou-structure.ps1
has caught up.

Run 00-preflight.ps1 for MS01 first (DNS servers pointed at DC01,
10.10.60.10).

Add-Computer triggers a reboot on success, so this script's two halves
(join, then move) run as separate invocations — the join half exits before
attempting the move, and the move half only runs once the domain-join check
at the top already passes.
#>
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

$domain = (Get-CimInstance Win32_ComputerSystem).Domain
if ($domain -ne 'ad.bluegillbass.lab') {
    $cred = Get-Credential -Message 'Domain admin credential (e.g. BLUEBASS\Administrator) to join MS01'
    Add-Computer -DomainName 'ad.bluegillbass.lab' -Credential $cred -Restart -Force
    Write-Host 'Joined and rebooting. Re-run this script afterward to confirm and move the computer object.'
    exit 0
}

Write-Host 'Already joined to ad.bluegillbass.lab — checking computer object placement.'

if (-not (Get-WindowsFeature RSAT-AD-PowerShell).Installed) {
    Install-WindowsFeature RSAT-AD-PowerShell | Out-Null
}
Import-Module ActiveDirectory

$targetOU = 'OU=Servers,OU=Corp,DC=ad,DC=bluegillbass,DC=lab'
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$targetOU'" -ErrorAction SilentlyContinue)) {
    Write-Host "OU=Servers doesn't exist yet — run 20-ou-structure.ps1 on a DC, then re-run this script to move MS01's computer object there."
    exit 0
}

$computer = Get-ADComputer -Identity 'MS01'
if ($computer.DistinguishedName -like "*,$targetOU") {
    Write-Host "MS01's computer object is already in OU=Servers — no change."
} else {
    Move-ADObject -Identity $computer.DistinguishedName -TargetPath $targetOU
    Write-Host "Moved MS01's computer object into OU=Servers."
}
