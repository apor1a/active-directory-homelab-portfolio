# Build progress

This is a condensed, skills-focused version of the private repo's working
session log — same phases, same bugs, same fixes, without the minute-by-minute
infrastructure narration (real IPs, exact commands against real hosts, etc.).

## Phase status

| Phase | State | Exit condition |
|---|---|---|
| 1 — Network | **done** for AD-lab purposes | 5 VLANs built and firewalled behind OPNsense; two test VMs on different zones proved routing works and the lab cannot reach the upstream household network |
| 2 — Templates | **done** | Windows Server 2025 Core and Windows 11 templates built, generalized (sysprep), and validated via linked clone |
| 3 — Directory | **in progress** | First domain controller promoted and verified (`Get-ADDomain`, `Get-ADReplicationFailure` clean, DNS self-resolving). Second DC and member server exist as VM shells, not yet promoted — needed for a real replication test |
| 4 — Telemetry | not started | Sysmon, audit GPOs, SIEM agents |
| 5 — Simulation | not started | Atomic Red Team, staged weaknesses, attack VM over VPN |
| 6 — Detection | not started | Sigma rules → SIEM detections, per-exercise runbooks |

## Real bugs found along the way

The point of building this instead of reading about it: almost every phase
surfaced something that looked correct in a GUI or in code review and simply
didn't work, for a reason that wasn't obvious until it was actually run.

**DHCP silently not answering on a new VLAN.** A DHCP relay's socket type
defaulted to `udp`, which is a known issue on this firewall platform — it
never answers `DHCPDISCOVER` on VLAN sub-interfaces with a `udp` socket.
Packets were confirmed arriving via `tcpdump`; nothing was ever offered back.
Fixed by setting the socket type to `raw`.

**A new VLAN interface bound to the wrong parent.** A VLAN device was bound to
the WAN parent interface instead of the LAN trunk since the day it was
created — invisible until something actually tried to use it, months later,
and confirmed with a 0-packet capture on the interface itself. Looked correct
everywhere else (bridge tagging, firewall rules); passed zero packets.

**Firewall rules that looked right and matched nothing.** Two separate
instances: a cloned rule that kept the *source* zone from the interface it was
cloned from (matched nothing on the new interface), and an inter-zone admin
rule placed on the destination zone's interface instead of the source zone's
— traffic is filtered based on where it arrives, not where it's headed, so the
rule looked entirely correct in the GUI and simply never fired.

**Windows Update failing with a cryptic SSL error.** Root cause, found via
`Get-WindowsUpdateLog` rather than guessing: a certificate revocation check
(served over plain HTTP even for an HTTPS connection) was failing because the
new VM's network zone had *no* firewall rules permitting DNS or internet
egress at all — it had only ever been used for an ICMP-only isolation test.

**Sysprep failing twice, for two different reasons.** First, an IPv6 tunnel
adapter (Teredo/6to4/ISATAP) that had no reason to exist on an IPv4-only lab
blocked generalization; disabling it without rebooting first didn't fully take
effect, and the retry corrupted the VM's generalization state enough that a
clean reinstall was the only real fix. Second attempt (different VM, lesson
applied): Windows 11 auto-encrypts the OS volume via Device Encryption even on
a local account — sysprep refuses to run with any BitLocker state active,
including "in progress but not yet protecting."

**An invalid enum value that looked plausible.** `Install-ADDSForest
-ForestMode 'Win2016'` isn't valid — Server 2016 shipped under the internal
codename "Threshold," and the parameter's actual value is `WinThreshold`.
There is no `Win2016` or `Win2019` value at all; only the cmdlet's own error
message lists the real set.

**An idempotency guard that produced a false "already done."** A promotion
script checked for a Windows service's *existence* to decide whether the
domain controller had already been promoted — but that service registers the
moment the underlying feature installs, well before promotion actually runs.
After an early failed attempt, every re-run silently short-circuited on this
false positive and printed a success-looking message while nothing had
actually happened. Fixed by checking for the AD database file itself, the
only thing that exists after a genuinely completed promotion. The same class
of bug turned up again in a user-import script, where user creation and group
membership were gated behind a single existence check — fixed by gating each
half of the operation on its own real state instead of a shared proxy.

**A network category that silently reset.** SSH access disappeared after
reboots and after sysprep, more than once, for related but not identical
reasons — Windows resets the "Private/Public" network identity on
generalization and, it turned out, on some plain reboots too. The Windows
Firewall's default SSH rule only allows Private/Domain profiles, so every
inbound attempt was dropped before the perimeter firewall was ever involved.
Confirmed to resolve permanently once these hosts are domain-joined, since
domain-authenticated networks stop relying on that heuristic at all.

**A silent clock skew with no fully confirmed root cause.** Windows guests
under this hypervisor interpret the virtual RTC as local time by default, when
it's actually true UTC — flagged as a real risk for domain promotion
specifically, since Kerberos rejects clock skew beyond five minutes and a
skewed DC produces promotion failures that look unrelated to time.

**Script files silently mangled by encoding.** Seven PowerShell scripts,
written with em-dashes in comments, were saved as UTF-8 without a byte-order
mark. Windows PowerShell 5.1 doesn't auto-detect UTF-8 without one and falls
back to the system codepage — which is what produced a wall of parser errors
the first time the scripts actually ran, despite having been reviewed and
looking correct.

## What's next

Promote the second domain controller (the real test of replication — a lone
DC can't prove it), join the member server, then build out the OU structure,
security groups, and 50+ synthetic users from a CSV import. After that, Phase
4 (telemetry) and the actual point of the lab: instrumenting it well enough to
tell the difference between normal activity and an attack.
