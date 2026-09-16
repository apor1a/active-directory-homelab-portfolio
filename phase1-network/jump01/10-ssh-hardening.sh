#!/bin/bash
# Run on seneca as root.
#
# JUMP01 (VMID 106) was built by hand 2026-08-31 — see
# phase1-network/opnsense/vlan-interfaces.md "Secure remote access". Its
# admin SSH key was dropped in at build time but never scripted, and its
# sshd_config relied on Debian's compiled-in defaults (PermitRootLogin
# commented out => implicit prohibit-password) instead of an explicit,
# version-controlled setting. This script makes both authoritative: it
# rewrites authorized_keys to contain exactly the dedicated lab keypair
# (dropping any other key that happens to be present, e.g. one that also
# unlocks seneca/cato) and pins the three auth directives explicitly,
# closing PasswordAuthentication globally rather than only for root.
#
# Safe to re-run after a from-scratch rebuild of JUMP01: every step is
# idempotent. Also safe in the "something went wrong" sense — this never
# touches JUMP01 over the network. `pct exec` attaches to the container
# directly through Proxmox, so even a bad sshd_config edit stays
# recoverable from seneca regardless of what happens to sshd.
set -euo pipefail

CTID=106
PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMkmJJJzmgyLrGqZusXQGh3zW3ks4tAn/AHBPPyhknx2 ad-lab-jump01"

if ! pct status "$CTID" &>/dev/null; then
    echo "ERROR: container $CTID not found on this node." >&2
    exit 1
fi

changed=0

# --- 1. Authoritative key management ---------------------------------
current_keys=$(pct exec "$CTID" -- cat /root/.ssh/authorized_keys 2>/dev/null || true)
if [ "$current_keys" != "$PUBKEY" ]; then
    pct exec "$CTID" -- mkdir -p /root/.ssh
    pct exec "$CTID" -- chmod 700 /root/.ssh
    printf '%s\n' "$PUBKEY" | pct exec "$CTID" -- tee /root/.ssh/authorized_keys > /dev/null
    pct exec "$CTID" -- chmod 600 /root/.ssh/authorized_keys
    echo "authorized_keys rewritten to the dedicated lab key."
    changed=1
else
    echo "authorized_keys already matches the dedicated lab key — no change."
fi

# --- 2. Explicit sshd hardening ---------------------------------------
SSHD_CFG=/etc/ssh/sshd_config
want_lines=(
    "PermitRootLogin prohibit-password"
    "PubkeyAuthentication yes"
    "PasswordAuthentication no"
)
directives=(PermitRootLogin PubkeyAuthentication PasswordAuthentication)

needs_edit=0
for i in "${!directives[@]}"; do
    d="${directives[$i]}"
    want="${want_lines[$i]}"
    if ! pct exec "$CTID" -- grep -qxF "$want" "$SSHD_CFG"; then
        needs_edit=1
    fi
done

if [ "$needs_edit" -eq 1 ]; then
    pct exec "$CTID" -- cp "$SSHD_CFG" "$SSHD_CFG.bak.$(date +%Y%m%d-%H%M%S)"
    for i in "${!directives[@]}"; do
        d="${directives[$i]}"
        want="${want_lines[$i]}"
        # Match only an actual (possibly commented-out) directive line —
        # "#Directive value" or "Directive value" with the # immediately
        # adjacent to the name, per Debian's sshd_config convention. Must
        # NOT match free-text comments like "# Directive.  Depending on
        # your PAM configuration," which use "# " (space after #) and
        # sentence punctuation instead of a value — an earlier version of
        # this script matched those too and clobbered explanatory prose
        # into a duplicate directive line.
        pct exec "$CTID" -- bash -c "
            if grep -qE '^[[:space:]]*#?${d}[[:space:]]+[^[:space:]]' '$SSHD_CFG'; then
                sed -i -E 's|^[[:space:]]*#?${d}[[:space:]]+[^[:space:]].*|${want}|' '$SSHD_CFG'
            else
                echo '${want}' >> '$SSHD_CFG'
            fi
        "
    done
    echo "sshd_config directives pinned explicitly: ${want_lines[*]}"
    changed=1

    echo "Validating sshd config before reload..."
    pct exec "$CTID" -- sshd -t
    pct exec "$CTID" -- systemctl reload ssh
    echo "sshd reloaded."
else
    echo "sshd_config already pins all three directives explicitly — no change."
fi

if [ "$changed" -eq 0 ]; then
    echo "Nothing to do — JUMP01 already converged on the desired state."
fi
