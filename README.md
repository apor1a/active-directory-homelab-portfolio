# AD Security Homelab

A Windows Active Directory environment, built, instrumented, and (eventually)
defended on a small self-hosted Proxmox
cluster. Bluegill & Bass LLP is a fictional law firm with a real active directory architecture that mirrors the basic organizational units of a real law practice. Everything here is synthetic — a fictional law firm, fictional staff,
fictional domain — built to teach me
about Active Directory environments without breaking something important.

> **Note on this repo.** This is a sanitized portfolio copy of a private
> working repo. Anything that identifies my real home network — host IPs, the
> ISP, and the domain my AD lab is delegated under — is marked
> `REDACTED FOR PRIVACY` or swapped for a placeholder (the AD domain itself
> reads as `bluegillbass.lab` throughout, since the scripts need a real,
> consistent domain name to stay readable). Everything else, including the
> automation scripts and the bugs found while writing them, is unedited.

## Why this exists

I'm a CTI analyst with a Linux/network background, learning Windows, AD, and
PowerShell by building a "real" enterprise environment from scratch. The manual creation and all inevitable failures are part of the design principle of the project.

| This lab does | Because |
|---|---|
| Small domain (2 DCs, 1 member server, 3 endpoints), deep instrumentation | Enough for real Kerberos/replication/GPO/SMB behavior given my hardware constraints |
| **Server Core only** — no GUI on any server | Forces me to do it the hard way and learn powershell. Every change becomes a script I can re-run, tweak, and refine over time as I get better. |
| SIEM on separate hardware | This is both security best practice and a hardware constraint. If the domain is compromised, the telemetry shouldn't live on the same machine. Also RAM is expensive |
| Offense runs off a separate machine, over VPN, through a real firewall boundary | Real network telemetry instead of loopback traffic that teaches bad habits |

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
- **RANGE** — offense traffic, reached over a WireGuard tunnel from a
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

## How I use AI here — a learning assistant, not a crutch

I use an AI coding assistant to help build this, and I've deliberately set
the rules of that collaboration up so it accelerates the learning instead of
replacing it:

- **I have to understand every change before it lands.** The assistant
  explains *why* a cmdlet or design choice is correct, not just what to run —
  and where AD offers two legitimate ways to do something, it tells me both
  and says which one an administrator would actually reach for.
- **It doesn't silently fix code I've reviewed and approved.** When the
  assistant flags a problem in an existing script, the rule is: say what was
  wrong first, before touching it. Several of the real bugs in
  [`PROGRESS.md`](PROGRESS.md) — the invalid `WinThreshold` enum value, the
  idempotency guard that produced a false "already done" — sat in
  scripts that had already been written and reviewed, and only surfaced once
  they actually ran against a real domain controller. Review doesn't replace
  hands-on execution, and I don't treat it like it does.
- **High-stakes changes start in review, not execution.** Anything touching
  the firewall's internet-facing rules, a domain controller promotion, or a
  bulk GPO edit gets planned and shown to me before anything runs — nothing
  destructive executes on autopilot.
- **Synthetic data and no committed secrets are non-negotiable**, regardless
  of how a request is phrased — nothing from my employer touches this lab,
  and there's no scenario where the assistant commits a credential on my
  behalf.

The point of all of it: the assistant handles the mechanical scaffolding
(idempotency checks, boilerplate, catching a typo'd cmdlet parameter) so I
spend my time on the part that's actually the goal — reading `Get-WinEvent`
output, understanding why Kerberos rejects a skewed clock, working out why a
firewall rule that looks correct doesn't fire. I still hit that class of bug
myself, on my own scripts, running against my own domain controller. That's
the intended outcome, not a gap in the process.

## Stack

Proxmox VE · OPNsense · Windows Server 2025 (Core) · Windows 11 · PowerShell ·
Wazuh · Sigma · Atomic Red Team

---

*Synthetic data only. No data, credentials, or configuration from my employer
appears anywhere in this repo or the lab it describes.*
