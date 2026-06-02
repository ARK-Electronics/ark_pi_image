#!/usr/bin/env bash
# Write the built golden image to an SD card / USB device.
# Usage: ./flash.sh <device>     e.g. /dev/sda, /dev/mmcblk0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
STAGING="$SCRIPT_DIR/staging"

IMG="${IMG:-$STAGING/ark-os-pi-${ARK_OS_VERSION}.img}"
DEV="${1:-}"

[ -f "$IMG" ] || { echo "ERROR: image not found ($IMG). Run ./build.sh first." >&2; exit 1; }

if [ -z "$DEV" ]; then
    echo "Usage: ./flash.sh <device>     e.g. /dev/sda, /dev/mmcblk0"
    echo
    echo "Candidate removable devices:"
    lsblk -dpno NAME,SIZE,MODEL,TRAN | awk '$NF=="usb" || $1 ~ /mmcblk/ {print "  " $0}'
    exit 1
fi

[ -b "$DEV" ] || { echo "ERROR: $DEV is not a block device." >&2; exit 1; }

# Refuse to write to the disk that holds the running root filesystem.
ROOT_SRC="$(findmnt -no SOURCE / 2>/dev/null || true)"
ROOT_PK="$(lsblk -no PKNAME "$ROOT_SRC" 2>/dev/null | head -1 || true)"
if [ -n "$ROOT_PK" ] && [ "$DEV" = "/dev/$ROOT_PK" ]; then
    echo "ERROR: $DEV holds the running system (mounted at /). Refusing to flash it." >&2
    exit 1
fi

SIZE="$(lsblk -dno SIZE "$DEV" | xargs)"
MODEL="$(lsblk -dno MODEL "$DEV" 2>/dev/null | xargs || true)"
echo "About to OVERWRITE all data on:"
echo "  device: $DEV  ($SIZE  ${MODEL:-unknown})"
echo "  image : $IMG"
read -rp "Re-type the device path to confirm: " confirm
[ "$confirm" = "$DEV" ] || { echo "Mismatch; aborting."; exit 1; }

# Unmount any partitions of the target before writing.
for part in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
    sudo umount "$part" 2>/dev/null || true
done

echo "==> Writing image (several minutes)…"
sudo dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
sync
echo "==> Done. Insert the card into the Pi and power on."
