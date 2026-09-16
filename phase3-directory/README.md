# phase3-directory

Numbered, idempotent scripts that build the forest from a fresh set of VMs —
`DC01`, `DC02`, `MS01` — through OUs, groups, and the synthetic `staff.csv`
roster. Design source of truth: `../docs/homelab-architecture.md`,
"The environment" section.

## Script sequence

| Script | Runs on | Does |
|---|---|---|
| `00-preflight.ps1` | DC01 / DC02 / MS01, pre-join | Static IP, DNS client, network category, `RealTimeIsUniversal`, hostname — fixes for the per-clone gotchas found in Phase 2 (see script header and `STATUS.md`) |
| `10-promote-dc01.ps1` | DC01 | `Install-ADDSForest` — new forest `ad.bluegillbass.lab` / `BLUEBASS` |
| `15-promote-dc02.ps1` | DC02 | `Install-ADDSDomainController` — joins DC02 to the forest as a second DC |
| `17-join-ms01.ps1` | MS01 | Domain-joins MS01 as a member server; moves its computer object into `OU=Servers` once that OU exists |
| `20-ou-structure.ps1` | DC01 or DC02 | Builds the OU tree — `Tier0`, `Corp/Users/{Legal,Finance,HR,IT,Records}`, `Corp/Groups`, `Corp/Workstations`, `Corp/Servers`, `ServiceAccounts`, `Disabled` |
| `30-groups.ps1` | DC01 or DC02 | Department security groups (`SG-Legal`, etc.) + `SG-FileServer-RW` |
| `40-users-import.ps1` | DC01 or DC02 | Bulk-imports `data/staff.csv` into department OUs and groups |

Run in order. Each script checks for existing state before creating
anything, so re-running after a partial failure is safe — this is also the
repo's rebuild test (see root `README.md`).

## Deployment convention

These are Server Core boxes with no GUI — copy this whole folder (scripts +
`data/staff.csv`, keeping the relative layout) to the target host, then run
scripts from an **interactive** SSH session, not a `ssh host 'powershell -c
...'` one-liner. Several scripts prompt for secrets (`Read-Host
-AsSecureString`, `Get-Credential`), which needs a real interactive shell to
work.

## Secrets

`10-promote-dc01.ps1`, `15-promote-dc02.ps1`, and `40-users-import.ps1`
prompt interactively for the DSRM and default-user passwords by default. Set
`$env:DSRM_PASSWORD` / `$env:DEFAULT_USER_PASSWORD` first (matching
`secrets/lab-credentials.env`) only if a non-interactive re-run is needed —
that trades away the protection an interactive prompt gives (the value never
touches this process's environment block). See each script's header for the
full tradeoff.

## Open / deferred

- **Static IP scheme is proposed, not yet confirmed against a real host**:
  `DC01=10.10.60.10`, `DC02=10.10.60.11`, `MS01=10.10.60.12`, leaving
  `.100+` free for Kea's DHCP pool.
- **Audit-policy / PowerShell-logging GPOs are deferred to Phase 4**
  (decided 2026-09-01). The design doc lists them under both Section 4's
  "controls to implement" and Phase 4's telemetry exit condition — they
  belong with the rest of the Sysmon/Wazuh build, not here. What Phase 3
  itself still owes on the GPO front (a baseline domain password policy, a
  Tier0-scoped GPO) is still undecided and not yet scripted; the next number
  in this sequence would be `50-` whenever that gets picked up.
- VM shells for `DC01`/`DC02`/`MS01` don't exist yet. Nothing above has been
  run against a real host.
