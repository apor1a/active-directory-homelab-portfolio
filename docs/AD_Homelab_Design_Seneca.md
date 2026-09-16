# AD SECURITY HOMELAB — SENECA BUILD
### A right-sized redesign for a 48 GB Ryzen 5 3600 cluster

**Design objective:** Learn to build, run, break, and defend a Windows Active
Directory environment using PowerShell as the primary interface. Everything that
does not serve that goal gets cut.

> **STATUS — 27 Aug 2026.** Design complete and reconciled against real hardware.
> Build not started. **Next action: Phase 1, first milestone** — two throwaway
> Debian VMs on VLANs 20 and 30, prove they route through `FW01`, prove the lab
> cannot reach the upstream household LAN, and scan the WAN from outside.
>
> Open decisions: whether a managed switch is ever worth buying; whether to
> add Velociraptor in Phase 6. Domain name resolved 2026-09-01 —
> `ad.bluegillbass.lab`, see Section 4.

---

## 0. Why this design, in plain terms

**The problem.** You read networks and adversaries well. You do not yet read
Windows. Almost every intrusion you write about ends inside somebody's Active
Directory, and right now you are describing that part secondhand.

**The fix.** Build a small real domain and make it your own responsibility. Run
it, instrument it, attack it, then explain what the evidence actually says.

**Four decisions, and the reason for each:**

1. **Small domain, deep instrumentation.** Two DCs, one member server, three
   endpoints. Enough for real Kerberos, replication, GPO and SMB behavior. Small
   enough that you know every host by name and every alert has an explanation.
2. **No GUI on the servers.** Server Core removes the option to click. Every
   change becomes a script you can re-run, diff, and commit. That is the fastest
   route to PowerShell fluency, and it is why the lab is small — you cannot
   script your way through fifteen servers while learning the cmdlets.
3. **The SIEM sits apart from what it watches.** Wazuh on Cato, not on the host
   running the domain. Same reason production log stores live on separate
   infrastructure: if the estate is compromised, the evidence should not be.
4. **Offense lives off the cluster.** Attacks come from the workstation, over a
   VPN, through the firewall. The traffic crosses a real boundary and produces
   real telemetry instead of a loopback that teaches you nothing.

**What it teaches, mapped to the day job:**

| Skill the lab builds | Where it pays off at work |
|---|---|
| Building and running AD from PowerShell | Reading intrusion reports about objects you've actually created |
| Kerberos, LDAP, SMB, NTLM under normal load | Knowing whether an artifact is strange or completely ordinary |
| Sysmon, Windows event IDs, audit policy | Judging what a victim organization could plausibly have seen |
| Writing and tuning Sigma detections | Turning intelligence into something a SOC can deploy tomorrow |
| Tiering, LAPS, gMSA, delegation | Recommending controls that survive contact with real constraints |
| Attack path analysis | Explaining why one foothold became domain admin |
| Firewall zoning and egress control | Assessing whether your own containment advice is realistic |

**The success test is not "the alert fired."** It is: reproduce an action,
correlate host and network evidence, reach a defensible conclusion, write a
detection for it, and reset the range for the next one.

---

## 1. What changes from the source guide, and why

| Source guide says | This build does | Reason |
|---|---|---|
| Security Onion, 24–32 GB | Wazuh all-in-one, 8 GB | SO alone is 60% of Seneca's RAM. Wazuh AIO handles 25 agents on 4 vCPU / 8 GB. |
| Dedicated Zeek/Suricata sensor + SPAN | Suricata on OPNsense; sensor VM optional in Phase 6 | You already run Corelight and Suricata professionally. Build for the gap, not the strength. |
| Full packet capture, 2–4 TB sensor storage | Targeted `tcpdump` during exercises only | 540 GB/day is not a learning objective. It is a storage bill. |
| 7 VLANs incl. DMZ, Home/IoT, Sensor | 5 zones | DMZ and IoT teach nothing about AD. Fewer zones, more rules you actually understand. |
| Desktop Experience servers | **Server Core everywhere** | Saves ~2 GB per server VM and makes PowerShell mandatory. This is the single highest-leverage decision in the build. |
| 8 VMs on one host | Split across Seneca, Cato and the gaming workstation | Cato is idle capacity and takes the SIEM. Offensive tooling leaves the cluster entirely. |
| AD CS in Phase 3 | AD CS in Phase 6, optional | ADCS is a rabbit hole. Earn it. |

**Cut list, explicit:** Arkime, tcpreplay, DMZ VLAN, IoT VLAN, dedicated Zeek
sensor VM, second application server, managed switch purchase, full packet
capture. Velociraptor and AD CS are deferred to Phase 6, not cut.

**Kept from the existing homelab:** OPNsense (becomes `FW01`), the GPU dev VM,
the file server, Grafana. Nothing gets thrown away.

---

## 2. Resource budget

### Seneca (48 GB, Ryzen 5 3600 — 6c/12t, 1.5 TB)

| VM | OS / role | vCPU | RAM | Disk | State |
|---|---|---:|---:|---:|---|
| *(host, ARC capped at 4 GB)* | Proxmox VE | — | 5 GB | — | — |
| `FW01` **(existing)** | OPNsense + Suricata IDS | 4 | 4 GB | 20 GB | always |
| `FILE01` **(existing)** | LXC — Samba | 2 | 1 GB | bind mount | always |
| `GRAF01` **(existing)** | LXC — Grafana | 1 | 512 MB | 10 GB | always |
| `DC01` | WS 2025 **Core** | 2 | 4 GB | 60 GB | always |
| `MS01` | WS 2025 **Core** | 2 | 4 GB | 80 GB | always |
| `WKS01` | Win 11 Ent (eval) | 2 | 4 GB | 60 GB | always |
| `DC02` | WS 2025 **Core** | 2 | 4 GB | 60 GB | on demand |
| `ADM01` | Win 11 Ent (eval) | 2 | 4 GB | 60 GB | on demand |
| `WKS02` | Win 11 Ent (eval) | 2 | 4 GB | 60 GB | on demand |
| `DEV01` **(existing)** | Linux + GTX 1660 passthrough | 6 | 12 GB | existing | on demand |

**Three operating modes:**

| Mode | Running | RAM | Free |
|---|---|---:|---:|
| Idle | Always-on set only | 22.5 GB | 25.5 GB |
| Exercise | \+ `ADM01`, `WKS02`, `DC02` | 34.5 GB | 13.5 GB |
| Everything | \+ `DEV01` | 46.5 GB | 1.5 GB |

**RAM is no longer the binding constraint — vCPU is.** Everything at once is
~26 vCPU against 12 threads. That runs, but under a CALDERA op with `DEV01`
compiling, expect contention. Keep `DEV01` on-demand and the problem never
surfaces.

Set `onboot=1` with a startup order on the always-on set, `onboot=0` on the rest:

```bash
# --- Seneca ---
qm set 100 --onboot 1 --startup order=1,up=30    # FW01 first, always
qm set 110 --onboot 1 --startup order=2,up=20    # DC01
qm set 111 --onboot 1 --startup order=3          # MS01
qm set 130 --onboot 1 --startup order=4          # WKS01
qm set 112 --onboot 0                            # DC02   on demand
qm set 140 --onboot 0                            # ADM01  on demand
qm set 141 --onboot 0                            # WKS02  on demand
qm set 200 --onboot 0                            # DEV01  on demand

# --- Cato ---
qm set 300 --onboot 1 --startup order=1          # PBS
qm set 310 --onboot 1 --startup order=2          # SIEM01
```

A mode switch beats remembering what's running:

```bash
#!/bin/bash   # /usr/local/bin/labmode
DEMAND="112 140 141"    # DC02 ADM01 WKS02
DEV="200"               # DEV01

down(){ for v in $@; do qm shutdown $v --forceStop 1 --timeout 90 & done; wait; }
up(){   for v in $@; do qm start $v; sleep 5; done; }

case "$1" in
  exercise) down $DEV;          up $DEMAND ;;
  dev)      down $DEMAND;       up $DEV ;;
  idle)     down $DEMAND $DEV ;;
  status)   qm list | awk 'NR==1 || $3=="running"' ;;
  *)        echo "usage: labmode {exercise|dev|idle|status}" ;;
esac
```

**Storage:** budget ~400 GB on Seneca on top of whatever `DEV01` and `FILE01`
already consume. Linked clones keep this well under a naive per-VM estimate.
Wazuh indices now live on Cato, not here.

### Cato (16 GB, 4c, 1 TB HDD + 256 GB SSD)

| VM | OS | vCPU | RAM | Storage | State |
|---|---|---:|---:|---|---|
| *(host)* | Proxmox VE | — | 2 GB | — | — |
| `PBS` | Proxmox Backup Server | 2 | 4 GB | HDD datastore | always |
| `SIEM01` | Ubuntu 24.04 + Wazuh AIO | 4 | 8 GB | SSD, 150 GB | always |

**Total: 14 GB / 16 GB.** Moving the SIEM off Seneca is the single biggest win
in this revision. It frees 8 GB on the busy node and puts the log store on
separate hardware from everything it monitors, which is how you'd build it in
production anyway.

Two operational notes: Cato's 4 cores are the floor for a Wazuh all-in-one, so
**schedule PBS backup windows outside exercise windows** or the indexer will
drop events while the backup runs. And keep Wazuh indices on the 256 GB SSD, not
the HDD — at 30-day retention with roughly eight agents, 150 GB is generous.

### Gaming workstation (offensive platform)

Attack tooling moves off the cluster entirely. This is better than a VM on Cato:
the traffic crosses a physical wire, the tooling gets real CPU, and the memory
hogs stop competing with the targets.

| Workload | Notes |
|---|---|
| `ATTACK01` — Kali | The primary offensive seat |
| BloodHound CE | Neo4j + Postgres, 4–6 GB. Intermittent and hungry — belongs here. |
| MITRE CALDERA | Server-side C2 for multi-stage emulation |

- **Use VMware Workstation Pro** (free for personal use), not Hyper-V. Enabling
  Hyper-V turns on VBS and will cost you gaming performance and trip some
  anti-cheat. Keep the hypervisor userspace.
- **Never install offensive tooling on the host OS.** It lives in a VM you can
  delete.
- **Connectivity: WireGuard road-warrior tunnel into `FW01`**, with the peer's
  tunnel address treated as a RANGE member by firewall policy. This avoids
  fighting Windows NIC drivers for 802.1Q tagging, and gives you a real VPN
  config to build. Point a subdomain of your own domain at the WAN IP for it.

### AWS

Keep it as the corosync quorum witness. Optionally sync PBS off-site.
**Do not run Windows in EC2 for this lab** — Windows licensing on EC2 is metered,
DC replication over WAN adds failure modes you don't want while learning, and
you'd be paying to relearn what Seneca does for free.

The one cloud extension worth doing later is **Entra ID + Entra Connect**
(Phase 7). Free tier, no EC2 cost, and hybrid identity attacks are directly
relevant to an AMLAW 100 threat model. That's Azure, not AWS.

### Proxmox tuning

```bash
# Cap ZFS ARC at 4 GB — default is 50% of RAM (24 GB), which will eat your lab
echo "options zfs zfs_arc_max=4294967296" > /etc/modprobe.d/zfs.conf
update-initramfs -u -k all && reboot

# Confirm KSM is reclaiming memory across near-identical Windows guests
systemctl status ksmtuned
cat /sys/kernel/mm/ksm/pages_sharing
```

- CPU type `host` on every VM. Enable the VirtIO balloon driver on Windows
  guests (install virtio-win guest tools) so you can overcommit safely.
- Build `WS2025-Core` and `Win11` **templates**, then use **linked clones**.
  Saves ~40 GB and cuts a 30-minute build to 30 seconds.
- The GTX 1660 stays with `DEV01`. Note that PCIe passthrough **pins that guest's
  memory** — no ballooning, no KSM sharing. Its 12 GB is fully allocated whenever
  it runs, which is why it stays on-demand.

---

## 3. Network design — 5 zones

| VLAN | Zone | Subnet | Contents |
|---:|---|---|---|
| 10 | MGMT / SOC | 10.10.10.0/24 | `FW01` LAN, `SIEM01` and `PBS` (both on Cato), `JUMP01` |
| 60 | CORP-SRV | 10.10.60.0/24 | `DC01`, `DC02`, `MS01` |
| 65 | CORP-CLI | 10.10.65.0/24 | `WKS01`, `WKS02`, `ADM01` |
| 50 | RANGE | 10.10.50.0/24 | `ATTACK01` (via WireGuard), CALDERA, BloodHound |
| 70 | HOMELAB | 10.10.70.0/24 | `DEV01`, `FILE01`, `GRAF01` |

*(Originally 20/30 in this doc's first draft — reassigned to 60/65 on
2026-08-30 to avoid colliding with tags already live on the separate,
pre-existing homelab. See `STATUS.md` for the full history. `JUMP01`, a
Tailscale subnet-router LXC, was added to MGMT/SOC on 2026-08-31 as the admin
access path into CORP-SRV/CORP-CLI — it wasn't in the original design.)*

`FW01` is the OPNsense you already run. Add tagged VLAN interfaces to it rather
than building a second firewall. Proxmox management stays on the upstream LAN so
a bad firewall rule can never lock you out of the hypervisor.

### WAN posture — you are in the ISP router's DMZ

The ISP router forwards all unsolicited inbound traffic to `FW01`'s WAN. There is
no NAT hiding you. That is fine, and it makes WireGuard easy, but it raises the
stakes on three rules:

- **WAN is default-deny inbound.** The only permitted inbound is the WireGuard
  listener. Nothing else, ever.
- **No WebGUI, no SSH, no SNMP bound to WAN.** Verify from outside, not from the
  config page.
- **Never port-forward into a lab zone.** The staged weaknesses in Section 4 are
  meant to be exploitable. They must never be reachable from the internet.

Verify with an external scan after Phase 1 and again any time you touch WAN rules.

Household devices live upstream on the household LAN. Add an explicit outbound
**deny to that subnet from every lab VLAN** — otherwise your only separation is
a routing accident.

VLAN 70 holds the pre-existing homelab. It is a **peer** of the lab zones, not a
parent. Nothing in CORP or RANGE has any business reaching it.

> **When to nest a second firewall:** the moment you want to detonate live
> malware rather than run Atomic Red Team and CALDERA. Known tooling against
> known targets is fine behind one firewall. Unknown samples are not — at that
> point put a second OPNsense between RANGE and everything else.

### Physical plumbing without buying a switch

Create a VLAN-aware Linux bridge `vmbr1` on both nodes. Most unmanaged switches
pass 802.1Q-tagged frames untouched, so trunking VLANs between Seneca and Cato
usually just works. Test it first:

```bash
# On Seneca and Cato: /etc/network/interfaces
auto vmbr1
iface vmbr1 inet manual
    bridge-ports enp3s0
    bridge-stp off
    bridge-fd 0
    bridge-vlan-aware yes
    bridge-vids 10,50,60,65,70
```

If tags get stripped, fall back to a **Proxmox SDN VXLAN zone**, which tunnels
the lab networks between nodes over plain IP and ignores the switch entirely.

### Starting firewall policy

| Source | Destination | Rule |
|---|---|---|
| CORP-CLI | CORP-SRV | Allow 53, 88, 123, 135, 389, 445, 464, 636, 3268-3269, 49152-65535. **Log all.** |
| CORP-CLI/SRV | MGMT | Allow tcp 1514, 1515, 55000 (Wazuh agent) only |
| MGMT | All | Allow (admin plane) |
| ADM01 | CORP-SRV | Allow 3389, 5985-5986 |
| RANGE | CORP-* | **Deny by default.** One disabled floating rule you toggle per exercise. Log aggressively. |
| RANGE | MGMT | Deny, always. No exceptions. |
| RANGE | HOMELAB | **Deny + alert.** `FILE01` is exactly the pivot a breakout wants. |
| CORP-* | HOMELAB | Deny. The lab has its own file server (`MS01`). |
| HOMELAB | CORP-* | Deny, except `GRAF01` → Proxmox metrics endpoint |
| WireGuard peers | — | Treated as RANGE members. Same rules, no exceptions. |
| Any lab | upstream household LAN subnet | **Deny + alert.** The household is upstream now. |
| Any lab | Internet | Allow 80/443/DNS. Block tcp/25 outbound. |

That RANGE→CORP toggle is the whole safety model. Make it one rule with a clear
description so flipping it is deliberate.

---

## 4. The environment

Domain: **`ad.bluegillbass.lab`** — a delegated subdomain of
`bluegillbass.lab`, which you own. Never publish public DNS records for it.
This avoids `.local` (deprecated, Bonjour conflicts) and avoids squatting on a
name you don't control.

Build a fictional law firm. You know the vertical, so the alerts will have
context you can actually reason about. Departments: Legal, Finance, HR, IT,
Records. Org: **Bluegill & Bass LLP**, NetBIOS `BLUEBASS`. Founding partners
Frank Bluegill, Esq. and Billy Bass, Esq. — both Legal/Partner in `staff.csv`.

### OU structure

```
DC=ad,DC=bluegillbass,DC=lab
├── OU=Tier0              (Tier-0 admin accounts, ADM01's computer object —
│                           NOT the DCs, see note below)
├── OU=Corp
│   ├── OU=Users
│   │   ├── OU=Legal
│   │   ├── OU=Finance
│   │   ├── OU=HR         (Trout — HR Coordinator)
│   │   ├── OU=IT
│   │   └── OU=Records
│   ├── OU=Groups         (SG-Legal, SG-Finance, SG-HR, SG-IT, SG-Records,
│   │                       plus role groups e.g. SG-FileServer-RW)
│   ├── OU=Workstations   (WKS01, WKS02)
│   └── OU=Servers        (MS01 — member servers only)
├── OU=ServiceAccounts
└── OU=Disabled
```

Two things this structure is doing on purpose:

- **Department sub-OUs under `Users`**, not one flat bucket, so a GPO can be
  scoped to Legal without touching Finance. `OU=Groups` exists alongside
  them because fine-grained password policies (PSOs) apply to **security
  groups**, not OUs — you'll want both mechanisms once Section 4's controls
  (LAPS, separate Tier-0 identities) get built.
- **`DC01`/`DC02`'s computer objects stay in the built-in `OU=Domain
  Controllers`**, created automatically at promotion. Don't move them into
  the custom `Tier0` OU above — that built-in OU carries the linked *Default
  Domain Controllers Policy*, and relocating the objects silently drops that
  GPO link unless you re-link it by hand. `Tier0` here is for Tier-0 **user**
  accounts and `ADM01`'s computer object only.

### Controls to actually implement, in order

1. Advanced audit policy via GPO (4624/4625/4688/4768/4769/4776/5140)
2. PowerShell script block + module logging (4103/4104)
3. Command-line process auditing in 4688
4. Windows LAPS
5. Separate Tier 0 admin identities, `ADM01` as the only privileged seat
6. gMSA for a scheduled task on `MS01`
7. AD Recycle Bin
8. Sysmon with a maintained config (SwiftOnSecurity or Olaf Hartong's modular set)

### Deliberate weaknesses to stage (after baseline works)

Kerberoastable SPN account with a weak password. A user with
`DONT_REQ_PREAUTH`. An over-permissive share ACL on `MS01`. A password in a GPP
or a description field. Unconstrained delegation on `MS01`. Add these **one at a
time**, and only after you can prove the baseline telemetry is clean.

---

## 5. Detection stack

**Wazuh all-in-one** on `SIEM01`. Not Splunk — Splunk Free strips out alerting
and user roles entirely, which makes detection engineering impossible on it.
Wazuh is unlimited, free, has a real rule engine, and includes agents, FIM, and
active response in one 8 GB box.

```bash
curl -sO https://packages.wazuh.com/4.x/wazuh-install.sh
sudo bash ./wazuh-install.sh -a
```

**Collection map**

| Source | Channel | Answers |
|---|---|---|
| All Windows | Security | Logons, privilege use, object access |
| All Windows | Sysmon/Operational | Process trees, network conns, image loads |
| All Windows | PowerShell/Operational | Script block content |
| `DC01`/`DC02` | Directory Service, DNS Server | Kerberos, LDAP, replication |
| `FW01` | Firewall + DNS via syslog → Wazuh | Policy decisions, egress |
| `FW01` | Suricata IDS alerts | Signature hits on inter-VLAN traffic |
| *(P6, optional)* | A small Zeek VM | Session metadata, if you ever want it |

Convert Sigma rules to Wazuh format with `sigma-cli` and the Wazuh backend when
you want community detection content.

---

## 6. PowerShell track — goal #2, made concrete

Server Core forces this. Every task below should be done in a script, committed
to a git repo, and re-runnable from scratch.

**Promotion:**

```powershell
Install-WindowsFeature AD-Domain-Services,DNS -IncludeManagementTools
Install-ADDSForest -DomainName 'ad.bluegillbass.lab' `
  -DomainNetbiosName 'BLUEBASS' `
  -ForestMode WinThreshold -DomainMode WinThreshold `
  -InstallDns -Force
```

*(Server 2025 offers a 2025 functional level. Start at the "2016" level — you
want the option to add older-behavior test cases later. The PowerShell enum
name for it is `WinThreshold`, not `Win2016` — Server 2016's internal
codename was "Threshold" and the enum was never renamed to match; there is no
`Win2016` or `Win2019` value at all. Found the hard way when
`10-promote-dc01.ps1` ran for the first time, 2026-09-15 — see STATUS.md.)*

**Structure:**

```powershell
$Base = 'DC=ad,DC=bluegillbass,DC=lab'
'Tier0','Corp','ServiceAccounts','Disabled' | ForEach-Object {
    New-ADOrganizationalUnit -Name $_ -Path $Base -ProtectedFromAccidentalDeletion $true
}
'Users','Groups','Workstations','Servers' | ForEach-Object {
    New-ADOrganizationalUnit -Name $_ -Path "OU=Corp,$Base" -ProtectedFromAccidentalDeletion $true
}
'Legal','Finance','HR','IT','Records' | ForEach-Object {
    New-ADOrganizationalUnit -Name $_ -Path "OU=Users,OU=Corp,$Base" -ProtectedFromAccidentalDeletion $true
}
```

**Bulk population from CSV:**

```powershell
Import-Csv .\staff.csv | ForEach-Object {
    $pw = ConvertTo-SecureString $_.Password -AsPlainText -Force
    New-ADUser -Name "$($_.First) $($_.Last)" `
        -SamAccountName $_.Sam -UserPrincipalName "$($_.Sam)@ad.bluegillbass.lab" `
        -Department $_.Dept -Title $_.Title `
        -Path "OU=$($_.Dept),OU=Users,OU=Corp,$Base" `
        -AccountPassword $pw -Enabled $true
}
```

*(`-Path` now resolves per-user via `$_.Dept`, so it lands each account in its
department's sub-OU — this depends on `staff.csv`'s `Dept` values matching the
OU names created above exactly, including case.)*

**Event analysis — the CTI-relevant skill.** Learn `Get-WinEvent` properly.
Parsing the XML beats guessing property indices:

```powershell
Get-WinEvent -FilterHashtable @{
    LogName   = 'Microsoft-Windows-Sysmon/Operational'
    Id        = 1
    StartTime = (Get-Date).AddHours(-2)
} | ForEach-Object {
    $d = ([xml]$_.ToXml()).Event.EventData.Data
    [pscustomobject]@{
        Time   = $_.TimeCreated
        User   = ($d | Where-Object Name -eq 'User').'#text'
        Parent = ($d | Where-Object Name -eq 'ParentImage').'#text'
        Image  = ($d | Where-Object Name -eq 'Image').'#text'
        Cmd    = ($d | Where-Object Name -eq 'CommandLine').'#text'
    }
} | Where-Object Parent -match 'winword|excel|outlook|mshta'
```

**Progression checklist**

- [ ] Forest built entirely from script, no GUI
- [ ] OUs, groups, 50+ synthetic users from CSV
- [ ] GPOs created and linked via the `GroupPolicy` module
- [ ] `Search-ADAccount` hygiene report (stale, locked, never-expires)
- [ ] `Get-ADReplicationFailure` / `repadmin` health check
- [ ] gMSA created and consumed by a scheduled task
- [ ] Windows LAPS deployed and password retrieved by script
- [ ] `Invoke-Command` fan-out across all endpoints
- [ ] A JEA endpoint restricting a helpdesk role
- [ ] A `Get-WinEvent` hunting function you actually reuse

---

## 7. Exercise ladder

| # | Exercise | What you're proving |
|---:|---|---|
| 1 | Normal domain activity for 48 h | You know what clean looks like |
| 2 | Failed logons, lockouts, password spray | Auth correlation, threshold tuning |
| 3 | RDP / WinRM / PsExec lateral movement | Same event, four sources |
| 4 | Atomic Red Team, 10 techniques | Technique-level detection coverage |
| 5 | BloodHound collection + path analysis | Privilege graph, then close a path and re-run |
| 6 | Kerberoast + AS-REP roast | Ticket telemetry, 4769 encryption types |
| 7 | CALDERA multi-stage op | Chained detection, gaps between stages |
| 8 | Full incident write-up | Timeline, scoping, containment, defensible conclusion |

Exercises 4–7 are driven from the gaming workstation over WireGuard. Everything
else runs from inside the lab.

**Guardrails:** snapshot before every exercise, restore after. RANGE→CORP rule
off by default. Synthetic data only — nothing from the firm ever touches this
lab, not a filename, not a username, not a domain.

---

## 8. Phased roadmap

| Phase | Deliverable | Exit condition | Est. |
|---|---|---|---|
| **1 — Network** | vmbr1, `FW01` VLAN interfaces, 5 VLANs, base ruleset, WireGuard | Two test VMs on different VLANs route through `FW01`; lab cannot reach the upstream household LAN; external WAN scan is clean | 1 wknd |
| **2 — Templates** | WS2025 Core + Win11 templates, linked clones, PBS jobs | A VM is built and restored in under 5 min | 1 evening |
| **3 — Directory** | `DC01`, `DC02`, `MS01`, OUs, users, GPOs — all scripted | `Get-ADReplicationFailure` clean; domain join works; whole forest rebuildable from git | 2 wknds |
| **4 — Telemetry** | Sysmon, audit GPOs, Wazuh agents, `SIEM01` on Cato | One logon and one process traced end-to-end across endpoint, DC, and firewall | 1 wknd |
| **5 — Simulation** | Atomic Red Team, staged weaknesses, `ATTACK01` over WireGuard | An exercise runs, alerts, and resets cleanly | ongoing |
| **6 — Detection** | Custom rules, dashboards, incident write-ups. Optional: AD CS, Velociraptor, a Zeek VM | Every exercise has evidence, a detection, and a response note | ongoing |
| **7 — Hybrid** *(optional)* | Entra ID tenant + Entra Connect | On-prem user authenticates to a cloud app | later |

### First milestone — do this before anything else

Two throwaway Debian VMs, one on VLAN 60 (CORP-SRV) and one on VLAN 65
(CORP-CLI). Ping across.
Confirm OPNsense logged the connection. Confirm the lab cannot reach your home
network. **If the isolation test fails, stop and fix it before a single Windows
ISO is downloaded.**

---

## 9. Honest tradeoffs

- **No physical switch or firewall.** You lose real SPAN and 802.1Q trunk
  experience. You already have that from work. Revisit if you ever want to
  practice packet capture at line rate.
- **Wazuh instead of Splunk/Elastic.** Wazuh's rule syntax is Wazuh-specific and
  less transferable than SPL or KQL. Mitigate by writing detections in **Sigma**
  first and converting. Sigma is the portable skill.
- **Server Core.** Slower at first. Painful the first weekend. It's the reason
  this lab teaches you PowerShell instead of teaching you where the buttons are.
- **The SIEM runs on Cato's 4 cores.** That is the ceiling of this design. When
  Wazuh starts dropping events, the first fix is a tighter Sysmon config, not
  more hardware.
- **The attack platform is a dual-use personal machine.** Tooling stays in a
  disposable VM, never the host OS, and WireGuard is the only path in.
- **Seneca remains a single point of failure for the domain.** Logs and backups
  now live on Cato, so an outage costs uptime rather than evidence. Test a
  restore before you need one.

---

## 10. References

| Source | URL |
|---|---|
| Wazuh quickstart / sizing | https://documentation.wazuh.com/current/quickstart.html |
| OPNsense VLAN setup | https://docs.opnsense.org/manual/how-tos/vlan_and_lagg.html |
| Proxmox SDN | https://pve.proxmox.com/pve-docs/chapter-pvesdn.html |
| Windows Server 2025 eval | https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025 |
| Administer AD DS (MS Learn) | https://learn.microsoft.com/en-us/credentials/applied-skills/administer-active-directory-domain-services/ |
| Atomic Red Team | https://github.com/redcanaryco/atomic-red-team |
| Sysmon config (Olaf Hartong) | https://github.com/olafhartong/sysmon-modular |
| Sigma | https://github.com/SigmaHQ/sigma |

*Synthetic data only. Verify current vendor requirements before committing.*
