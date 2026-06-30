#!/usr/bin/env bash
# Write the built golden image to an SD card / USB device.
# Usage: ./flash.sh <device>     e.g. /dev/sda, /dev/mmcblk0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
STAGING="$SCRIPT_DIR/staging"

# Image name matches build.sh: <target>-<codename>[-ark-os][-robotics][-hailo].img.
# build.sh appends a suffix per opted-in payload, so rather than enumerate the
# combinations, default to the NEWEST image matching this target+release — i.e. the one
# the last build produced. Pick a non-default target with `TARGET=<target> ./flash.sh
# <device>`, or point at an image directly with IMG=.
if [ -z "${IMG:-}" ]; then
    newest=""
    for f in "$STAGING/${TARGET}-${PIOS_RELEASE}.img" "$STAGING/${TARGET}-${PIOS_RELEASE}-"*.img; do
        [ -f "$f" ] || continue
        if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
    done
    # Fall back to the bare stock name (build.sh's no-payload output) for the error path.
    IMG="${newest:-$STAGING/${TARGET}-${PIOS_RELEASE}.img}"
fi
DEV="${1:-}"

if [ ! -f "$IMG" ]; then
    echo "ERROR: image not found ($IMG)." >&2
    echo "       Build it with ./build.sh $TARGET, or set TARGET=/IMG= to pick another." >&2
    if compgen -G "$STAGING/*.img" >/dev/null 2>&1; then
        echo "       Images present in staging/:" >&2
        for f in "$STAGING"/*.img; do echo "         $(basename "$f")" >&2; done
    fi
    exit 1
fi

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

# Tee the write to staging/flash.log.txt — after the confirm so tee buffering doesn't
# swallow the prompt.
exec > >(tee "$STAGING/flash.log.txt") 2>&1
echo "==> Flashing $IMG -> $DEV ($SIZE  ${MODEL:-unknown})"

# Unmount any partitions of the target before writing.
for part in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
    sudo umount "$part" 2>/dev/null || true
done

echo "==> Writing image (several minutes)…"
sudo dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
sync
echo "==> Done. Insert the card into the Pi and power on."
