#!/bin/bash
# Run on the node with a spare NIC, as root.
#
# This node's boot NIC carries vmbr0 — untagged management traffic on the
# upstream household LAN (REDACTED FOR PRIVACY). This adds a second,
# independent bridge (vmbr1) on a spare NIC's first port (enp1s0f0),
# VLAN-aware and trunking the five lab zones. vmbr0 is never touched: a
# mistake in the trunk or in FW01's rules can't cut off SSH/GUI access to
# the hypervisor, same principle every node in my cluster follows.
set -euo pipefail

IFACE=/etc/network/interfaces
PORT=enp1s0f0
VIDS=10,50,60,65,70

if grep -q "^auto vmbr1$" "$IFACE"; then
    echo "vmbr1 already present in $IFACE — nothing to do."
    exit 0
fi

if ! ip link show "$PORT" &>/dev/null; then
    echo "ERROR: $PORT not found. Confirm the spare NIC is seated and cabled." >&2
    exit 1
fi

cp "$IFACE" "$IFACE.bak.$(date +%Y%m%d-%H%M%S)"

cat >> "$IFACE" << EOF

auto vmbr1
iface vmbr1 inet manual
	bridge-ports $PORT
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids $VIDS
EOF

ifreload -a

echo "vmbr1 created. Verifying:"
ip -br link show vmbr1
bridge vlan show dev "$PORT"
