# Firewall VLAN interfaces

Configured by hand through the firewall's GUI — OPNsense has no clean
idempotent CLI for this, so this doc is my re-run record for rebuilding it
from scratch in the same order. No WAN interface or WAN rule was touched for
any of this; everything here is LAN-side.

## VLAN zones

| Tag | Zone | Subnet | Purpose |
|---:|---|---|---|
| 10 | MGMT/SOC | 10.10.10.0/24 | Jump box, log collection, backups |
| 50 | RANGE | 10.10.50.0/24 | Attack platform, reached over VPN |
| 60 | CORP-SRV | 10.10.60.0/24 | Domain controllers, member server |
| 65 | CORP-CLI | 10.10.65.0/24 | Domain-joined workstations |
| 70 | HOMELAB | 10.10.70.0/24 | The rest of my personal infrastructure |

Each interface is a static-IP VLAN device on the firewall's LAN trunk. I
originally planned CORP-SRV/CORP-CLI on tags 20/30, then reassigned them to
60/65 once I realized those tags were already committed elsewhere in my
homelab.

## DHCP

Kea DHCPv4 handles addressing for all five zones. One real gotcha here:
Kea's Socket Type setting defaults to `udp`, which silently never answers
`DHCPDISCOVER` on a VLAN sub-interface — confirmed via packet capture that
requests were arriving but nothing was ever offered back. The fix is a
global Socket Type = `raw` setting, not anything per-subnet, and it's the
first thing I check now if a new zone's DHCP silently doesn't work.

## Firewall policy

Deliberately minimal for the isolation milestone: ICMP allowed between
CORP-SRV and CORP-CLI for testing, everything else default-denied, plus an
explicit logged deny from every lab zone to my household LAN. DNS/HTTP/HTTPS
egress got added to each zone only once something in it actually needed the
internet — every zone starts with zero outbound access until I grant it
explicitly.

Two rule-authoring mistakes worth remembering, because both produced a rule
that looked entirely correct in the GUI and simply matched nothing:

- A cloned rule kept its **source** network from the zone it was cloned
  from, instead of being updated to match the new interface.
- An inter-zone admin rule has to live on the **source** zone's interface,
  not the destination's — traffic is filtered based on where it arrives, not
  where it's headed.

## Admin access

Direct SSH/RDP from my household network into a lab VLAN was never going to
work: my admin PC sits on the same subnet as the firewall's internet-facing
interface, which is default-deny from the firewall's own perspective. So I
built a small jump box on MGMT/SOC that runs as a VPN subnet router,
advertising routes into CORP-SRV and CORP-CLI. That lets any of my devices
already on that VPN reach the lab directly — it's a router, not a bastion, so
there's no login hop through the jump box itself.

The jump box runs only an SSH daemon and the VPN client; every admin rule
from it into a lab zone is scoped to its single IP, not the whole MGMT/SOC
subnet, and MGMT/SOC itself starts with zero rules beyond the deny-to-
household-LAN, same as every other zone.

## Isolation test — result: pass

Two throwaway VMs, one on CORP-SRV and one on CORP-CLI: cross-zone ping
passed, and both were confirmed unable to reach my home router or my
hypervisor. The blocked traffic showed up logged against the explicit deny
rule, not failing for some unrelated reason like a missing route.

---

*A few more real bugs found building this network — a VLAN device bound to
the wrong parent interface, a container that couldn't reach a VPN tun
device — are in [`../../PROGRESS.md`](../../PROGRESS.md).*
