#!/bin/bash
# Run on cato as root.
#
# The Proxmox installer created a ~141GB LVM-thin pool (VG pve, LV data) on
# cato's boot SSD but never registered it as usable storage — pvesm status
# didn't show it, and lvm-thin1/zfspool1 in storage.cfg are both scoped to
# seneca only. This just exposes that existing, empty pool to cato so VM
# disks (SIEM01) can land on it. It never touches cato-pbs, which owns the
# separate 1TB HDD entirely.
set -euo pipefail

STORCFG=/etc/pve/storage.cfg
STORAGE_ID=cato-lvm-thin
VG=pve
THINPOOL=data

if grep -q "^lvmthin: $STORAGE_ID$" "$STORCFG"; then
    echo "$STORAGE_ID already present in $STORCFG — nothing to do."
    exit 0
fi

if ! lvs "$VG/$THINPOOL" &>/dev/null; then
    echo "ERROR: LV $VG/$THINPOOL not found. Check 'lvs' output before re-running." >&2
    exit 1
fi

cp "$STORCFG" "$STORCFG.bak.$(date +%Y%m%d-%H%M%S)"

cat >> "$STORCFG" << EOF

lvmthin: $STORAGE_ID
	thinpool $THINPOOL
	vgname $VG
	content images,rootdir
	nodes cato
EOF

echo "$STORAGE_ID registered. Verifying:"
pvesm status | grep "$STORAGE_ID"
