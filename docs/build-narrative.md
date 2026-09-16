# Building an Active Directory Security Lab From Scratch

*A narrative account of designing and building a self-hosted AD security lab
on a two-node Proxmox cluster — written for anyone who wants the story, not
the raw commit log. The terse day-to-day record lives in `STATUS.md`; this
is the version with the reasoning left in.*

## Why build this

I work in cyber threat intelligence with a Linux and networking background.
Almost every intrusion I analyze ends up somewhere inside a Windows Active
Directory environment, and until this project I'd only ever read about that
part — never actually built, run, instrumented, attacked, or defended one
myself. Reading a report about Kerberoasting is different from having
generated a 4769 event, opened it in `Get-WinEvent`, and actually looked at
what a legitimate service-ticket request looks like next to a malicious one.

So the goal wasn't "stand up a domain." It was: build a small, real Windows
environment, take full ownership of it end to end — the network, the
identity plane, the logging, the attacks, the detections — and come out the
other side able to read AD-related evidence the way I already read network
evidence.

Four design decisions shaped everything that followed:

- **Small and deeply instrumented, not large and shallow.** Two domain
  controllers, one member server, a handful of workstations. Small enough
  that I know every host by name and every alert has a traceable cause —
  the opposite of a sprawling lab I'd only ever click through once.
- **No GUI on the servers.** Windows Server Core removes the option to
  click your way through a fix. Every change becomes a PowerShell command
  I have to actually understand, which is the fastest way I know to build
  real fluency rather than pattern-matching on menu locations.
- **The logging infrastructure lives on separate hardware from what it
  watches.** Same reason a real SOC doesn't put its log store on the box
  it's monitoring — if the lab domain gets compromised as part of an
  exercise, the evidence shouldn't be able to go down with it.
- **Attacks come from outside the cluster, over a real network boundary.**
  Offensive tooling runs on a separate machine, reaching in through a VPN
  and a firewall, so what I'm analyzing afterward is real cross-network
  telemetry — not a loopback connection that teaches nothing about how
  detection actually works in practice.

## The shape of the network

The lab runs on two Proxmox nodes — a main box with the compute budget for
the domain itself, and a second, smaller node that hosts backups and (later)
the SIEM, deliberately kept separate from what it's watching. Everything
sits behind OPNsense, which occupies an unusual position: it's in the
router's DMZ, meaning its WAN interface is genuinely internet-facing with no
NAT in front of it. That raised the stakes on network design from day one —
default-deny inbound on WAN, nothing bound to it but a VPN listener, and an
explicit rule denying every lab segment from ever reaching back out onto the
household network upstream.

Inside that boundary, the lab is split into five VLANs: a management/SOC
segment for administration and monitoring, a server segment for the domain
controllers and member server, a client segment for workstations, an
isolated attack-range segment for offensive tooling, and a segment for
unrelated homelab services that has nothing to do with the AD lab but shares
the same physical hardware. Each one is a real, firewalled boundary, not a
notional one — proven in Phase 1 by dropping two throwaway Linux VMs on
different segments, confirming they could reach each other where intended,
and confirming both were completely blocked from reaching the household
network, with the block visible and logged in the firewall's own log files.

Remote administration doesn't come in through a bastion host with a shared
login. It comes in through a Tailscale subnet router sitting on the
management segment, which means any device already on my personal
mesh network — including my own laptop — reaches the lab's internal subnets
directly and transparently, routed through the firewall like any other
internal host, no separate hop or login required. Getting that working
surfaced one of the more interesting bugs of the whole build: a brand-new
VLAN interface that looked completely correct in every layer of
configuration — the firewall rules, the switch tagging, the DHCP scope — but
was silently passing zero packets, because its underlying network device had
been bound to the firewall's *internet-facing* interface instead of its
internal one since the day it was created. Nothing had ever tried to use
that VLAN until the night I needed it, so the misconfiguration sat invisible
for weeks. Finding it meant working down through every layer with packet
captures at each hop until the one that showed zero frames arriving pointed
straight at the actual cause — a good reminder that "looks right in every
UI" and "actually works" are two different claims, and the gap between them
is usually a very specific, very findable thing once you stop guessing and
start measuring at each boundary.

## Building repeatable Windows infrastructure

Rather than install Windows by hand for every VM in the lab, Phase 2 was
about building two golden images — one Windows Server 2025 Core, one
Windows 11 — that get converted into Proxmox templates and then cloned in
seconds instead of reinstalled in half an hour. The value isn't just speed;
it's that every domain controller, every workstation, starts from the exact
same known-good baseline.

Getting there by hand once, on purpose, rather than scripting an unattended
install from the start, surfaced a long list of real Windows/virtualization
interactions that would otherwise have stayed invisible:

**Driver ordering matters more than it looks like it should.** A VirtIO
storage driver loaded during Windows Setup only covers the disk controller
— the network adapter is a completely separate driver package on the same
media, and Setup has no reason to touch it unless you tell it to. First
attempt, that meant a fully installed VM with literally no network adapter
detected at all. The fix that actually scales is loading every relevant
driver at Setup's driver-load screen in one pass, which stages them all into
the installed image so Windows' first-boot hardware detection binds
everything automatically — no manual driver installation after the fact.

**Virtual hardware clocks lie about what they represent.** The hypervisor
hands Windows guests a hardware clock holding true UTC, but Windows' default
assumption is that hardware clocks hold local time. Combined with an
initially-wrong timezone, this produced a Windows Update failure with an
error code that had nothing obviously to do with clocks, and took a genuine
investigation — ruling out DNS, ruling out proxy settings, before the actual
mechanism became clear via the Windows Update log rather than guesswork.
The real, underlying cause of that particular Update failure ended up being
something else entirely (a missing firewall egress rule — see below), which
is its own lesson: a red herring that's real and worth fixing doesn't mean
it's *the* cause of the problem in front of you.

**A freshly built firewall zone has no rules beyond what you explicitly
tested.** Every VLAN in this lab started with just enough firewall policy to
pass its Phase 1 connectivity test — nothing about actual internet egress.
That's fine right up until something inside that zone needs DNS or HTTPS,
which Windows Update very much does, including for the certificate
revocation checks it performs even before it downloads anything. Diagnosing
that meant working down through the actual failure signature in the Windows
Update log to a specific line about a certificate check failing over a
plain-HTTP revocation lookup — and once framed that way, tracing it back to
a firewall zone with zero permitted egress was straightforward. This same
gap showed up independently on three different network zones over the
course of the build, which says something about how easy it is to build a
zone, pass its one intended test, and never notice it has no path to the
internet until something inside it actually needs one.

**Sysprep needs a lot more respect than a normal command.** Windows'
generalization tool — the thing that strips a machine-specific identity out
of an installed OS so it's safe to clone — failed the first time I ran it,
on an unrelated IPv6 tunnel-adapter cleanup issue (this lab is IPv4-only
throughout, so those adapters had no reason to exist and were disabled, but
the fix needed a reboot to fully take before it would work). Retrying
immediately, without giving that fix time to settle, is what actually did
the damage: the second attempt failed differently, and by then the tool's
own internal state had already been partially torn down by the first
attempt, leaving the VM in a corrupted, un-recoverable position with no
snapshot to fall back to. That one was on me, not a Windows quirk — a
destructive operation without a safety net first is always a mistake, and
the lab's own rules said as much even before I'd internalized it the hard
way. Every sysprep attempt since has been preceded by a snapshot, no
exceptions, and the second template build benefited directly: two more
sysprep failures happened on that build (Windows 11's TPM-driven background
disk encryption and a Windows-Update-in-progress conflict over reserved
disk space, both genuinely new interactions specific to a TPM-equipped
guest that the TPM-less server build had never triggered), and neither one
put anything real at risk, because both failed during sysprep's own
pre-flight validation, before any actual teardown of machine state had
started. Reading the tool's own log to know *which kind* of failure you're
looking at — a safe validation failure versus real mid-operation damage —
turned out to be the difference between a two-minute fix and a from-scratch
reinstall.

**A generalized image doesn't remember everything you configured on it.**
The template's network was explicitly marked as a trusted, private network
before generalization — but every clone made from that template came up
treating its network as untrusted again, because Windows re-identifies its
network fresh on every clone's first boot rather than inheriting the
template's last-known state. That single setting controls whether the
built-in firewall even allows inbound administrative access at all, so every
clone was silently unreachable until that got manually corrected — a fix
that works but obviously doesn't scale to dozens of workstation clones.
The actual fix is to bake the *policy* that governs that setting into the
template, rather than the live setting itself, since a policy is durable
across generalization in a way that live, per-network state isn't.

## Where the project stands

Both the server and the workstation golden images are through their
Windows Setup and post-install configuration, with a shared, idempotent
script now capturing every fixup that's been proven identically across
both builds — installing the hypervisor's guest tools, correcting the clock
behavior, enabling remote administration, disabling what doesn't belong in
an IPv4-only network — so that step never has to be re-derived from memory
or a scrollback buffer again. Alongside the hands-on template work, the
groundwork for the next phase has already been laid out on paper: the
domain's organizational structure, over fifty synthetic staff records for
a fictional law firm built specifically so every alert in later phases has
a plausible, explainable business context behind it, and the full sequence
of PowerShell scripts that will promote the domain controllers and
populate the directory — written, reviewed, and deliberately not yet run
against real infrastructure, in keeping with a rule I set for myself early
on: one phase finishes before the next one starts for real.

What's ahead follows directly from the four decisions this whole design
started from: promote the actual domain and populate it from those scripts;
wire up host and network logging with the SIEM sitting apart from what it
watches; run real, staged attack techniques from outside the cluster over
the VPN boundary; and, for every technique run, produce an actual detection
— written first in a vendor-neutral detection language before being
converted into whatever the SIEM natively speaks, so the detection itself
stays portable even if the tooling around it doesn't.

## What this is actually for

None of this is meant to look like a finished product. The value was never
"a domain exists" — it's the accumulated set of real problems this build
has already forced me to actually solve: a network interface that looked
correct everywhere and simply wasn't, a firewall zone that passed its one
intended test and nothing else, a destructive operation retried without a
safety net, two platform-specific quirks that only a Windows 11 guest with a
virtual TPM would ever surface, a security setting that quietly doesn't
survive the exact operation meant to make it reusable. Every one of those
is a small, honest example of the kind of root-cause reasoning that
matters far more in this field than knowing the right command to type —
and every one of them is now something I've actually diagnosed myself,
from first principles, instead of read about secondhand.
