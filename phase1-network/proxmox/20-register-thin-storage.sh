#!/bin/bash
# Run on the node hosting backups and the SIEM, as root.
#
# The Proxmox installer created a ~141GB LVM-thin pool (VG pve, LV data) on
# this node's boot SSD but never registered it as usable storage — pvesm
# status didn't show it, and my other thin/ZFS storage entries in
# storage.cfg are scoped to my other cluster node only. This just exposes
# that existing, empty pool to this node so VM disks (the SIEM VM) can land
# on it. It never touches this node's backup datastore, which owns a
# separate disk entirely.
set -euo pipefail

STORCFG=/etc/pve/storage.cfg
STORAGE_ID=secondary-lvm-thin
VG=pve
THINPOOL=data
NODE=$(hostname)

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
	nodes $NODE
EOF

echo "$STORAGE_ID registered. Verifying:"
pvesm status | grep "$STORAGE_ID"
