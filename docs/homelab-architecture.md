# My Homelab's AD Security Architecture

I built this lab to close a specific gap: I read intrusion reports about
Active Directory environments constantly, but I'd never actually run one. I
know networks and adversaries well; I didn't yet know Windows from the
inside. So I built a small, real domain and made it my own responsibility —
stand it up, instrument it, attack it, then explain what the evidence
actually says.

## Design principles

A few decisions shape everything else here:

- **Small and deeply instrumented, not sprawling.** Two domain controllers,
  one member server, a handful of endpoints — enough for real Kerberos,
  replication, GPO, and SMB behavior, small enough that I know every host by
  name and every alert has an explanation.
- **No GUI on the servers.** My domain controllers and member server run
  Windows Server Core. That removes the option to click through a wizard —
  every change becomes a script I can re-run, diff, and commit, which is the
  fastest way I know to actually learn PowerShell instead of learning where
  the buttons are.
- **The SIEM sits apart from what it watches.** My detection stack runs on
  separate hardware from the domain it monitors — the same principle
  production log stores follow: if the domain is compromised, the evidence
  shouldn't be.
- **Offense lives outside the lab entirely.** Attacks come from a separate
  machine, over a VPN, through my firewall. The traffic crosses a real
  network boundary and produces real telemetry, instead of loopback traffic
  that teaches nothing.

## Architecture

My homelab runs on a small self-hosted Proxmox cluster behind an OPNsense
firewall, split into five isolated network zones:

| Zone | Purpose |
|---|---|
| MGMT/SOC | Admin access, log collection, backups |
| CORP-SRV | The domain controllers and member server |
| CORP-CLI | Domain-joined workstations |
| RANGE | Where offense happens — reachable only over VPN, firewalled off from everything else by default |
| HOMELAB | The rest of my personal infrastructure, unrelated to the AD lab |

Each zone boundary is enforced at the firewall, not assumed — isolation
between zones gets tested directly rather than just configured and trusted.

**My firewall sits in my ISP router's DMZ**, so its WAN interface is directly
internet-facing with no NAT in front of it. That raises the stakes on a short
list of rules I treat as non-negotiable: WAN is default-deny inbound with
nothing but a VPN listener open, nothing administrative is ever bound to WAN,
and nothing in the lab is ever port-forwarded to the internet — the
deliberately vulnerable configurations I stage later are meant to be found by
tools running inside the lab, never by the internet.

The path from RANGE (offense) into the rest of the lab is disabled by default
and only enabled by hand, one rule, for the duration of an exercise.

## The environment

I built a fictional law firm inside the domain — a vertical I understand well
enough that the alerts have context I can actually reason about. Fictional
departments, fictional staff, fictional everything — nothing from my actual
work ever touches this lab.

The organizational unit structure mirrors what I'd expect to administer for
real: department-scoped OUs so a Group Policy Object can target one
department without affecting another, a separate OU for security groups
since fine-grained password policies attach to groups rather than OUs, and a
Tier-0 OU reserved strictly for privileged accounts — kept separate from the
domain controllers' own built-in OU, since moving DC computer objects out of
their default location silently breaks the policy linked to it.

Controls I'm building toward, roughly in order: advanced audit policy,
PowerShell script-block logging, Windows LAPS, tiered admin accounts backed
by a single privileged workstation, group-managed service accounts, and a
maintained Sysmon configuration. Once that baseline telemetry is clean, the
plan is to stage deliberate weaknesses one at a time — the kind of
misconfigurations that actually show up in real environments, like
kerberoastable accounts, over-permissive share ACLs, and credentials left
somewhere they shouldn't be.

## Detection

My SIEM ingests Windows security and Sysmon logs from every host,
directory-service and DNS logs from the domain controllers, and
firewall/IDS logs from the perimeter — enough to trace a single logon or
process across the endpoint, the domain, and the network in one pass. I
write detections in Sigma first and convert them to my SIEM's native format,
since Sigma is the portable, reusable artifact and the platform-specific rule
is just a build output of it.

## Exercise plan

Once the baseline is instrumented, the plan is a ladder of exercises:
establishing what normal domain activity looks like, correlating
authentication events across sources, working through lateral-movement
techniques, running an actual attack-emulation framework against the lab, and
finishing with a full incident write-up — timeline, scoping, containment, a
defensible conclusion. Every exercise gets snapshotted and reset, and the
guardrail that makes the whole thing safe to run is that the path from the
attack zone into the rest of the lab stays off unless I've deliberately
turned it on.

## Where AI fits into this

I build this with an AI coding assistant, and every architectural call
above — the zone boundaries, what's Server Core versus GUI, where the SIEM
lives, how offense stays off the cluster — is mine, made deliberately, not
generated and accepted. The assistant is a learning tool here, not a
replacement for doing the work: it has to explain *why* a design or a cmdlet
is right rather than just supplying it, and it doesn't fix a script I've
already reviewed without first saying what was actually wrong with it. The
real bugs documented in [`PROGRESS.md`](../PROGRESS.md) — an invalid enum
value, an idempotency check that lied about its own state, a VLAN device
wired to the wrong interface — are exactly the kind of thing that only shows
up once you actually run infrastructure, not something a design conversation
would have caught. That's the gap this lab exists to close, and outsourcing
the running of it would defeat the point.

## What I gave up to keep this small

A few honest tradeoffs. I don't have a managed switch or a second physical
firewall, so I'm not getting hands-on with real port mirroring or trunk
hardware — I already get plenty of that at work, so it wasn't worth building
here. My SIEM's rule syntax is platform-specific rather than a broadly
transferable query language, which is exactly why every detection gets
written in Sigma first. And Server Core is slower to work with at first —
that friction is the point; it's what forces the PowerShell fluency this
whole lab exists to build.

---

*Full build progress, including the real bugs I hit getting here, is in
[`PROGRESS.md`](../PROGRESS.md).*
