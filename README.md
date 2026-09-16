# AD Security Homelab

A Windows Active Directory environment, built, instrumented, and (eventually)
attacked and defended, entirely from scripts, on a small self-hosted Proxmox
cluster. Everything here is synthetic — a fictional law firm, fictional staff,
fictional domain — built to close a specific gap: reading intrusion reports
about Active Directory environments without ever having run one.

> **Note on this repo.** This is a sanitized portfolio copy of a private
> working repo. Anything that identifies my real home network — host IPs, the
> ISP, and the domain my AD lab is delegated under — is marked
> `REDACTED FOR PRIVACY` or swapped for a placeholder (the AD domain itself
> reads as `bluegillbass.lab` throughout, since the scripts need a real,
> consistent domain name to stay readable). Everything else, including the
> automation scripts and the bugs found while writing them, is unedited.

## Why this exists

I'm a CTI analyst with a Linux/network background, learning Windows, AD, and
PowerShell by building the thing I usually only read about after it's already
been compromised. The design principle driving every choice below: **cut
anything that doesn't teach AD or PowerShell**, even when a "real" SOC lab
guide would include it.

| This lab does | Because |
|---|---|
| Small domain (2 DCs, 1 member server, 3 endpoints), deep instrumentation | Enough for real Kerberos/replication/GPO/SMB behavior; small enough to know every host by name |
| **Server Core only** — no GUI on any server | Removes the option to click. Every change becomes a script you can re-run, diff, and commit — the fastest route to PowerShell fluency |
| SIEM on separate hardware from what it watches | If the domain is compromised, the evidence shouldn't live on the same box |
| Offense runs off a separate machine, over VPN, through a real firewall boundary | Real network telemetry instead of loopback traffic that teaches nothing |

The full architecture write-up is in
[`docs/homelab-architecture.md`](docs/homelab-architecture.md).

## Architecture

Two-node Proxmox cluster, five network zones behind an OPNsense firewall:

```
                         ┌─────────────────────────┐
         ISP / internet ─┤   OPNsense (FW01)        │
                         │   default-deny inbound,   │
                         │   only VPN listener open  │
                         └────────────┬─────────────┘
                                      │
        ┌───────────────┬────────────┼────────────┬───────────────┐
        │                │            │            │               │
   MGMT/SOC (10)    RANGE (50)   CORP-SRV (60) CORP-CLI (65)  HOMELAB (70)
   jump box,        attack VM    DC01, DC02,   workstations   unrelated
   SIEM, backup      (via VPN)   MS01                          homelab VMs
```

- **CORP-SRV / CORP-CLI** — the AD lab itself: two domain controllers, one
  member server, Windows 11 workstations.
- **RANGE** — where offense happens, reached over a WireGuard tunnel from a
  separate physical machine, never from inside the cluster. Its firewall path
  to CORP is disabled by default and toggled by hand only for an exercise.
- **MGMT/SOC** — the SIEM (Wazuh) and backup server, deliberately off the same
  hardware as the domain, plus a jump box for admin access.

Every VLAN boundary is enforced in OPNsense, and the isolation is tested, not
assumed — see `phase1-network/` for the actual test.

## What this teaches, mapped to CTI work

| Building this | Pays off reading intel about |
|---|---|
| Standing up AD/DNS/DHCP from PowerShell, not a wizard | Objects and services I've actually created and broken |
| Kerberos, LDAP, SMB, NTLM under normal load | Whether a reported artifact is strange or completely ordinary |
| Sysmon config, Windows event IDs, audit policy | What a victim org could plausibly have seen, and what a gap in their logging means |
| Writing Sigma first, converting to a SIEM's native format | Turning finished intel into something a SOC can deploy tomorrow |
| OU/GPO tiering, LAPS, gMSA, delegation | Recommending controls that survive contact with real constraints |
| Firewall zoning and egress control on OPNsense | Assessing whether my own containment advice in a report is realistic |

## Status

Currently mid-build — DC01 is a real, verified domain controller; DC02 and a
member server exist as VM shells not yet promoted/joined. Telemetry, attack
simulation, and detection engineering (Phases 4–6) haven't started. Full
phase-by-phase progress, and the debugging stories that came out of getting
here, are in [`PROGRESS.md`](PROGRESS.md).

## How the repo is organized

```
docs/              Design doc and a narrative write-up of the build
phase1-network/    Proxmox bridges, OPNsense VLANs, isolation tests
phase2-templates/  VM template build (Server Core + Win11), linked clones
phase3-directory/  Numbered, idempotent AD build scripts (00-, 10-, 20-...)
phase4-telemetry/  Sysmon, audit GPOs, SIEM agent deployment (not started)
phase5-simulation/ Atomic Red Team runners, staged weaknesses (not started)
phase6-detection/  Sigma rules, converted SIEM detections (not started)
runbooks/          Per-exercise notes: what ran, what fired, what it means
secrets/           Credential template only — real secrets are never committed
```

Scripts are numbered and **idempotent** by design — re-running any of them
should never create a duplicate object. `phase3-directory/README.md` and
`PROGRESS.md` both cover a couple of times that guarantee was actually broken
and how it got fixed.

## How I work with an AI pair programmer here

The private repo this is drawn from is entirely CLAUDE.md-driven: every
infrastructure change is a script, nothing is configured by clicking, and a
few rules are non-negotiable regardless of how the request is phrased —
synthetic data only (nothing from my employer ever touches this lab), no
committed secrets, and any change to the firewall's WAN-facing rules gets an
explicit "what's changing and why" plus a prompt to verify externally, never
an assumption that it worked. The point of those rules is to keep the
learning honest: the assistant explains *why* a cmdlet or design choice is
correct instead of just running it, and doesn't silently fix a script I wrote
myself without saying what was wrong first.

## Stack

Proxmox VE · OPNsense · Windows Server 2025 (Core) · Windows 11 · PowerShell ·
Wazuh · Sigma · Atomic Red Team

---

*Synthetic data only. No data, credentials, or configuration from my employer
appears anywhere in this repo or the lab it describes.*
