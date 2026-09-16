<#
Builds the OU structure from the design doc, Section 4 — run once on DC01
(or DC02) after promotion. Idempotent: checks each OU's DN before creating
it, so re-running after a partial failure just fills in whatever's missing.

Order matters here — children have to be created after their parents exist,
which is why this isn't just a flat loop over every OU name at once.

DC01/DC02's own computer objects are deliberately NOT touched by this
script. They land in the built-in OU=Domain Controllers at promotion time,
which carries the linked Default Domain Controllers Policy GPO — moving
them into Tier0 would silently drop that link. Tier0 in this structure is
for Tier-0 user accounts and ADM01's computer object only (design doc,
Section 4).
#>
#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory

$ErrorActionPreference = 'Stop'
$Base = 'DC=ad,DC=bluegillbass,DC=lab'

function New-OUIfMissing {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    if (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue) {
        Write-Host "$dn already exists — no change."
    } else {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $true
        Write-Host "Created $dn."
    }
}

'Tier0', 'Corp', 'ServiceAccounts', 'Disabled' | ForEach-Object {
    New-OUIfMissing -Name $_ -Path $Base
}

'Users', 'Groups', 'Workstations', 'Servers' | ForEach-Object {
    New-OUIfMissing -Name $_ -Path "OU=Corp,$Base"
}

'Legal', 'Finance', 'HR', 'IT', 'Records' | ForEach-Object {
    New-OUIfMissing -Name $_ -Path "OU=Users,OU=Corp,$Base"
}
