# FW01 VLAN interfaces — Phase 1

Configured by hand through the OPNsense 26.1.6 GUI (reached via SSH tunnel —
see the root `CLAUDE.md` for the tunnel command). OPNsense has no clean
idempotent CLI for this, so this doc is the re-run record required by the
project's own rule: *"if a change was made by hand, it is not done until it
is scripted here and re-runnable from scratch."* Rebuilding FW01 from scratch
means redoing these exact steps in this exact order.

No WAN interface or WAN rule was touched for any of this — LAN-side only.

## VLAN tag decision

The design doc's VLAN 20 (CORP-SRV) and 30 (CORP-CLI) collide with the
existing, separate homelab migration: VLAN 20 is live (STASHBOX, formerly
also NERO-DEV/SAMBA dual-homed) and VLAN 30 is reserved for that same effort.
CORP-SRV/CORP-CLI use **60/65** instead. Full reasoning and the current VLAN
map are in `STATUS.md` under "Open decisions."

## Interfaces

| Tag | Description | Static IP | Notes |
|---:|---|---|---|
| 60 | CORP_SRV | `10.10.60.1/24` | Device `vlan06` |
| 65 | CORP_CLI | `10.10.65.1/24` | Device `vlan065` |
| 10 | MGMT_SOC | `10.10.10.1/24` | Built and confirmed working 2026-08-30 |
| 50 | RANGE | `10.10.50.1/24` | Built and confirmed working 2026-08-30. Intended for `ATTACK01`/CALDERA/BloodHound via WireGuard once that's built — see "Secure remote access" below |
| 70 | HOMELAB | `10.10.70.1/24` | Built and confirmed working 2026-08-30. Eventual home for STASHBOX/NERO-DEV, not migrated yet |

All five zones now exist. DHCP (Kea, socket type `raw`) and the explicit
logged deny-to-household-LAN rule are in place on all five.

Steps, per interface:
1. **Interfaces ‣ Devices ‣ VLAN ‣ Add** — parent = the physical/virtio port
   currently assigned as LAN (check Interfaces ‣ Assignments), VLAN tag as above.
2. **Interfaces ‣ Assignments** — assign the new VLAN device, give it the
   description above.
3. **Interfaces ‣ [name]** — enable, IPv4 Configuration Type = **Static IPv4**
   (not DHCP — DHCP here means the *router* would try to get an address from
   an upstream server, which doesn't exist on a new VLAN), address as above,
   IPv4 gateway rules = Disabled (this is a LAN-type zone, not routed).

## DHCP — Kea DHCPv4

**Known bug, hit and fixed tonight:** Kea's **Socket Type** defaults to `udp`
under Services ‣ Kea DHCP ‣ Kea DHCPv4 ‣ Settings. With `udp`, Kea silently
never answers DHCPDISCOVER on VLAN sub-interfaces — confirmed via `tcpdump` on
the LAN trunk NIC that discovers were arriving at OPNsense correctly tagged,
but no DHCPOFFER ever went out. This is a documented OPNsense/Kea issue
(opnsense/core #8745, #9756). **Fix: set Socket Type = `raw`.** This is a
global Kea setting, not per-subnet — if a future VLAN's DHCP silently doesn't
work, check this first before anything else.

Settings: Enabled ✅, Interfaces = all VLAN interfaces below, Socket Type =
`raw`, "Firewall rules: automatically add" ✅ (Kea inserts its own allow-DHCP
rule, so custom firewall rules don't need to account for bootp/bootps traffic).

| Interface | Subnet | Pool |
|---|---|---|
| CORP_SRV | `10.10.60.0/24` | `10.10.60.100 - 10.10.60.200` |
| CORP_CLI | `10.10.65.0/24` | `10.10.65.100 - 10.10.65.200` |
| MGMT_SOC | `10.10.10.0/24` | `10.10.10.100 - 10.10.10.200` |
| RANGE | `10.10.50.0/24` | `10.10.50.100 - 10.10.50.200` |
| HOMELAB | `10.10.70.0/24` | `10.10.70.100 - 10.10.70.200` |

Note: Kea's Pools field requires a plain hyphen with spaces (`100 - 200`), not
an en dash (`–`) — easy typo to copy-paste from formatted text/markdown.

"Auto collect option data" left checked — router/DNS options are pulled from
each interface's own static IP automatically.

## Firewall rules (Rules (New) — Unified Rules, not the Legacy per-interface pages)

OPNsense 26.1 replaced per-interface rule tabs with a single unified rules
table (Firewall ‣ Rules (New)), filtered by an interface dropdown at the top.
The old Firewall ‣ Rules page still exists as a "Legacy" plugin in parallel —
don't split rules across both.

Tonight's rules are deliberately minimal — just enough for the Phase 1
milestone test, not the full policy table from the design doc (Section 3),
which is a separate, later task:

**CORP_SRV:**
- Pass / ICMP / `10.10.60.0/24` → `10.10.65.0/24` — "Allow ping to CORP-CLI —
  isolation test" — logged
- Block / any / `10.10.60.0/24` → `REDACTED FOR PRIVACY` (household LAN subnet) — "Deny to upstream household LAN" —
  logged

**CORP_CLI:** mirror image of the above (source/dest swapped).

**MGMT_SOC / RANGE / HOMELAB:** just the explicit logged deny to
the household LAN subnet, same pattern — no inter-zone allow rules yet. Added by
cloning the CORP_SRV deny rule (Rules (New) supports clone/duplicate per row;
confirmed safe for our single-protocol rules — the known 26.1 clone bug only
affects rules with multiple protocols selected, e.g. TCP+UDP together).

No catch-all "block everything else" rule is needed — OPNsense default-denies
anything not explicitly passed.

**Egress rules added later (never recorded here until now):** both CORP_SRV
(2026-08-31, during the WS2025 template build — see `STATUS.md`) and CORP_CLI
(2026-09-01, during the Win11 template build) needed DNS/HTTP/HTTPS egress
added after the fact — each zone had only ever had the Phase-1 ICMP/deny
rules above, never actual internet access, until Windows Update needed it.
Same three rules on both zones' interfaces, below the household-LAN deny:

| Proto | Destination | Port | Description |
|---|---|---|---|
| TCP+UDP | This Firewall | 53 (domain) | Allow DNS to FW01 resolver |
| TCP | any | 443 (https) | Outbound HTTPS |
| TCP | any | 80 (http) | Outbound HTTP |

**Two rule-authoring gotchas hit adding CORP_CLI's copy tonight**, both worth
checking first if a cloned rule silently doesn't work:

1. **Source must match the interface it's actually on.** CORP_CLI's DNS rule
   was cloned from CORP_SRV's and kept `Source: CORP_SRV network` instead of
   being updated to `CORP_CLI network` — the rule looked right (correct
   interface tab, correct destination/port) but silently matched nothing,
   since traffic arriving on the CORP_CLI interface is never sourced from
   CORP_SRV's subnet. Symptom: `Resolve-DnsName` timing out even though the
   rule appears present.
2. **Interface must be the ingress zone, not the destination zone**, for
   inter-zone admin rules. A new JUMP01 → CORP_CLI SSH rule (see MGMT_SOC
   table below) was first added with `Interface: CORP_CLI` instead of
   `MGMT_SOC` — traffic from JUMP01 arrives at OPNsense via MGMT_SOC (that's
   where JUMP01 physically sits), so a rule filed under CORP_CLI's own
   interface never sees it. Every working JUMP01 admin rule lives on the
   MGMT_SOC tab with the *destination* field pointing at the target zone;
   this one just wasn't added that way at first. Symptom: SSH connection
   timing out (not refused) even with the Windows-side firewall/profile
   correctly configured.

## Secure remote access — built 2026-08-31

Came up when figuring out how to administer these VMs day-to-day: the
deny-to-household-LAN rules don't affect inbound admin access at all (wrong
direction) — the real blocker is that the admin PC sits on the same subnet as
`FW01`'s WAN interface (inherent to the DMZ setup), so it's already
WAN-default-deny from the firewall's perspective. Direct SSH/RDP from the
household network into a lab VLAN was never going to work here.

**Built:** `JUMP01` — Debian 12 LXC, VMID 106, on seneca. 1 vCPU / 1GB RAM /
8GB disk (`lvm-thin1`). `vmbr1`, tag 10 (MGMT_SOC), static `10.10.10.5/24`,
gw `10.10.10.1`. Runs `sshd` and `tailscaled` as a subnet router — nothing
else. Deliberately **not** on `FW01` itself (keeps the edge firewall's own
surface minimal) and **not** reusing the future `ATTACK01`/offensive
WireGuard tunnel (that stays a separate access tier into RANGE, kept apart
from routine admin access on purpose).

**Unprivileged-LXC + Tailscale gotcha** — this build's equivalent of the Kea
socket-type issue from the interface build above. Tailscale needs
`/dev/net/tun`, which Proxmox doesn't pass into an unprivileged container by
default; `tailscale up` fails silently on the tun device, not obviously on
networking. Fix, in `/etc/pve/lxc/106.conf`:
```
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file
```
Plus `net.ipv4.ip_forward=1` inside the container (required for any subnet
router). If a future rebuild has Tailscale silently not routing, check this
first.

**Tailscale config:**
```
tailscale up --advertise-routes=10.10.60.0/24,10.10.65.0/24,10.20.0.0/24 \
  --accept-dns=false --hostname=jump01
```
Routes advertised: CORP_SRV (60) and CORP_CLI (65) — forward-provisioned now
even though no Phase 3 VMs exist yet, so that phase doesn't need a second
firewall/Tailscale round-trip — and SERVICES (`10.20.0.0/24`, the separate
homelab-migration VLAN 20, covers NERO-DEV/STASHBOX). **Not** advertised:
RANGE (50, deliberately isolated — no admin path, by design), CTI (30) and
HOMELAB (70, both built but currently empty — add when something actually
lives there). Routes require manual approval per-device in the Tailscale
admin console even after the device itself is authorized — that's on the
account owner, not something `tailscale up` does alone.

**Admin SSH access to JUMP01 itself — scripted 2026-08-31.** The build
above dropped an SSH key onto JUMP01 by hand and never mentioned it; that's
now codified in `phase1-network/jump01/10-ssh-hardening.sh`, run from
seneca via `pct exec`. It authoritatively manages `authorized_keys` (a
dedicated `id_ed25519_ad_lab` keypair, kept separate from the key that also
grants root on seneca/cato — that key is no longer trusted here) and pins
`PermitRootLogin prohibit-password` / `PubkeyAuthentication yes` /
`PasswordAuthentication no` explicitly in `sshd_config` rather than relying
on Debian's implicit defaults. Idempotent, safe to re-run after a rebuild.

**OPNsense firewall rules — MGMT_SOC interface**, all sourced from
`10.10.10.5/32` (the jump box specifically, not the MGMT_SOC subnet):

| Proto | Destination | Port | Description | Logged |
|---|---|---|---|---|
| TCP | CORP_SRV net | 22 | JUMP01 → CORP_SRV SSH admin | yes |
| TCP | CORP_SRV net | 5985:5986 | JUMP01 → CORP_SRV WinRM admin | yes |
| TCP | CORP_CLI net | 3389 | JUMP01 → CORP_CLI RDP admin | yes |
| TCP | CORP_CLI net | 5985:5986 | JUMP01 → CORP_CLI WinRM admin | yes |
| TCP | CORP_CLI net | 22 | JUMP01 → CORP_CLI SSH admin (added 2026-09-01 — see "Two rule-authoring gotchas" above) | yes |
| TCP | HOMELAB net | 22 | JUMP01 → HOMELAB SSH admin (STASHBOX/NERO-DEV; replaced the old SERVICES-VLAN rule below when those hosts migrated 2026-08-31) | yes |
| TCP | any | 53 | JUMP01 outbound DNS | no |
| UDP | any | 53 | JUMP01 outbound DNS | no |
| TCP | any | 80 | JUMP01 outbound HTTP (apt) | no |
| TCP | any | 443 | JUMP01 outbound HTTPS (Tailscale control + DERP + apt) | no |

The last four exist because MGMT_SOC had **zero** rules before this — not
even outbound internet — so the jump box couldn't reach `apt` or Tailscale's
control plane until they were added. Mirrors the design doc's Section 3
"any lab → internet: allow 80/443/DNS" policy, applied here for the first
time. UDP 41641 (Tailscale's direct-connect port) was deliberately left out
for now — tied to the still-open OPNsense UDP-egress investigation in the
root `CLAUDE.md`; TCP 443 gets Tailscale working via DERP relay in the
meantime, same as STASHBOX today.

**Known cosmetic issue:** the CORP_CLI WinRM rule's description still reads
"JUMP01 → CORP_SRV WINRM Admin" (copy-paste artifact from cloning the
CORP_SRV WinRM rule) — the destination network is correct (CORP_CLI), only
the label is wrong. Harmless, worth a rename next time that rule list is open.

**Unrelated bug found and fixed during validation — NERO-DEV routing.**
Testing the SERVICES route (SSH to NERO-DEV, `10.20.0.11`) initially failed
even though every layer checked out: the firewall rule passed the SYN
(confirmed via a live capture on `vmbr1` showing OPNsense re-transmit the
packet from VLAN 10 straight onto VLAN 20 toward NERO-DEV's MAC), and
NERO-DEV's own `ufw`/sshd accepted it (iptables counter incremented on the
`22/tcp ACCEPT` rule). The reply just never made it back: NERO-DEV's routing
table (`ip route`) had a directly-connected route for `10.20.0.0/24` and a
*default* route out its original interface (`REDACTED FOR PRIVACY`, the household
LAN) — nothing for `10.10.0.0/16` at all. A SYN-ACK back to `10.10.10.5`
fell through to the default route and left via the wrong interface entirely,
bypassing OPNsense on the way out. Classic symptom of the "dual-homed
mid-migration" state `STATUS.md` already had flagged for VLAN 20 hosts.

Fixed on NERO-DEV itself (owner's machine, outside this repo) by adding a
route stanza to `/etc/netplan/60-vlan20.yaml`:
```yaml
network:
  version: 2
  ethernets:
    enp6s19:
      addresses: [10.20.0.11/24]
      routes:
        - to: 10.10.0.0/16
          via: 10.20.0.1
```
then `netplan apply`. `10.10.0.0/16` covers all five AD-lab zones in one
route so it won't need touching again as Phase 3 populates CORP_SRV/CORP_CLI.
Old config backed up to `60-vlan20.yaml.bak-preroute` on NERO-DEV. **Any
other VLAN-20 host that's dual-homed the same way (STASHBOX?) likely needs
the same fix if it ever needs to be reached from the lab side** — not
confirmed here, flagging for the homelab-migration effort in the root
`CLAUDE.md`, not fixed as part of this session.

**Validated 2026-08-31:**
| Test | Result |
|---|---|
| SSH to NERO-DEV (`10.20.0.11`) from `JUMP01` directly | Pass (post routing fix) |
| SSH to NERO-DEV from admin PC, over tailnet subnet route | Pass (post routing fix) |
| SSH to a throwaway VLAN-60 test LXC (VMID 998, destroyed after) from admin PC, over tailnet | Pass, clean |

**Update, later the same session:** STASHBOX and NERO-DEV were both migrated
off SERVICES (20) onto HOMELAB (70) — see "STASHBOX/NERO-DEV → HOMELAB
migration" below. `JUMP01`'s advertised routes changed accordingly:
`10.20.0.0/24` dropped, `10.10.70.0/24` added
(`tailscale up --advertise-routes=10.10.60.0/24,10.10.65.0/24,10.10.70.0/24`).
The MGMT_SOC → SERVICES admin rule was removed and replaced with
MGMT_SOC → HOMELAB (same port, 22).

## STASHBOX/NERO-DEV → HOMELAB migration (2026-08-31)

Moved the only two remaining hosts on the legacy SERVICES VLAN (20) onto
HOMELAB (70), the zone that was always the intended eventual home for them.
This let SERVICES be decommissioned entirely and freed the CTI (30)
reservation — neither legacy VLAN is in use anymore. Prerequisite: HOMELAB
had zero rules beyond deny-to-household-LAN before this (same rule-less state
MGMT_SOC was in before the jump box build), so DNS/HTTP/HTTPS egress rules
were added first — otherwise STASHBOX loses Tailscale the instant it's
re-tagged, since Tailscale is its only access path.

**Real bug found, not caused by this migration but blocking it entirely:**
HOMELAB's VLAN device (`vlan070`) had **Parent interface** set to `vtnet0`
(WAN) instead of `vtnet1` (LAN — the trunk actually wired to `vmbr1`, where
all of Proxmox's VLAN-tagged traffic lives). It had been wrong since HOMELAB
was first built 2026-08-30 — nothing had ever tried to actually use the
interface until tonight, so it went unnoticed. Everything downstream looked
correct (GUI config, Proxmox bridge tagging, firewall rules), which is what
made this one hard to spot: confirmed via a 0-packet OPNsense-side capture
taken directly on `vlan070` (25-byte file, just the empty pcap header) that
OPNsense's own OS never saw a single frame arrive, despite `tcpdump` on
seneca's `vmbr1` bridge showing the tagged frames correctly leaving Proxmox.
Fixed by changing the VLAN device's Parent to `vtnet1 (LAN)`. No WAN
exposure — the ISP router's DMZ doesn't hand OPNsense 802.1Q-tagged frames, so
the misrouted VLAN was simply dead the whole time, not leaking anything.
**If a future VLAN is built and looks correct everywhere but never passes
traffic, check the VLAN device's Parent interface first**, before anything
else — this is now the third category of "config says it works, runtime
doesn't" gotcha in this build, after Kea's socket type and the LXC tun
device.

**NERO-DEV** went from dual-homed to fully single-homed as part of this —
its household-LAN NIC (`vmbr0`) was removed entirely, not just re-tagged.
New config: `10.10.70.11/24` via `10.10.70.1`, normal default routing (the
`10.10.0.0/16 via 10.20.0.1` static-route patch from the SERVICES-era
routing bug is obsolete and was removed — single-homed hosts don't need it).

**STASHBOX** was already single-homed (only ever had one NIC, on VLAN 20),
so its migration was just: re-tag at Proxmox, fix its netplan address at the
OS level. Hit two smaller issues along the way, both self-inflicted typos
rather than anything structural: the first netplan edit was applied *before*
the Proxmox-level re-tag (should've been done in the other order — caused a
brief avoidable outage), and the replacement address was mistyped as
`10.10.70.1` — **the gateway's own address** — causing an IP conflict with
`FW01` itself until corrected to `10.10.70.10`. Both fixed within the same
session. Its stash webservice (`:9999`) was found stopped once networking
was confirmed working — unrelated to any of the above (SSH and Tailscale
both came back clean before this was noticed) and not yet diagnosed further,
deferred by the owner in the moment.

**SERVICES (20) decommissioned:** removed its Kea DHCP scope, its own rules
(deny-to-household-LAN plus whatever egress rules let STASHBOX/NERO-DEV reach the
internet while they lived there), disabled and removed the interface, then
deleted the underlying `vlan020` VLAN device. **CTI (30)** needed no
teardown — it was reserved for this same legacy migration but never actually
built, so it's simply no longer reserved; the tag is free for future use.

Confirmed via `bridge vlan show` on seneca that no VM/CT on the host has
anything tagged VLAN 20 before any of the teardown steps were taken.

**Validated post-migration:** both `stashbox` and `nero-dev` Tailscale nodes
online at their unchanged overlay IPs; SSH reaches both `10.10.70.10` and
`10.10.70.11` cleanly from `JUMP01` directly and from the admin PC over the
tailnet subnet route (auth-only failure, network path fully proven — no key
installed, as intended).

## Phase 1 milestone test — result: PASS (2026-08-30)

Two throwaway Debian 12 LXCs on seneca (VMIDs 998/999, tagged 60/65,
destroyed after the test):

| Test | Result |
|---|---|
| CORP-SRV → CORP-CLI ping | Pass |
| CORP-CLI → CORP-SRV ping | Pass |
| CORP-SRV → home ISP router (`REDACTED FOR PRIVACY`) | Blocked |
| CORP-SRV → seneca hypervisor (`REDACTED FOR PRIVACY`) | Blocked |
| CORP-CLI → home ISP router (`REDACTED FOR PRIVACY`) | Blocked |

Blocked traffic confirmed logged against the explicit deny rule in Firewall
‣ Log Files, not failing for an unrelated reason (e.g. missing route).

## Still open

- Full firewall policy table (design doc Section 3) — tonight only has the
  minimal allow/deny needed for testing, not the real inter-zone policy
- WireGuard for `ATTACK01`/RANGE (separate from the jump box's Tailscale use)
- External WAN scan (not urgent yet — no WAN changes have been made)
- Cosmetic: rename the mislabeled CORP_CLI WinRM rule description on MGMT_SOC
- STASHBOX's stash webservice (`:9999`) is stopped — found during the HOMELAB
  migration, unrelated to networking (confirmed working before this was
  noticed), not yet diagnosed
- SIFT is still on the legacy pattern's target list in the root `CLAUDE.md`
  ("Phase 6: roll forward remaining VMs") — its target is HOMELAB (70) now,
  not VLAN 20/30, which no longer exist
