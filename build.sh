#!/usr/bin/env bash
# Build the ARK-OS Raspberry Pi golden image: copy the stock image, grow its root
# partition, loop-mount it, bind-mount the kernel filesystems, and run provision.sh
# inside an arm64 chroot. Produces staging/ark-os-pi-<ver>.img.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
DOWNLOADS="$SCRIPT_DIR/downloads"
STAGING="$SCRIPT_DIR/staging"
export DOWNLOADS

STOCK_XZ="$DOWNLOADS/raspios-lite-arm64.img.xz"
[ -f "$STOCK_XZ" ] || { echo "ERROR: stock image not found ($STOCK_XZ). Run ./setup.sh first." >&2; exit 1; }

sudo -v || { echo "ERROR: sudo is required to build a disk image." >&2; exit 1; }

OUT_IMG="$STAGING/ark-os-pi-${ARK_OS_VERSION}.img"
ROOTFS="$STAGING/rootfs"
mkdir -p "$STAGING" "$ROOTFS"

# Safety net: a leaked bind mount under $ROOTFS from an interrupted run would make
# the operations below touch the host's /dev or /proc — refuse and let the operator
# unmount.
if mount | awk -v r="$ROOTFS" -v d="$ROOTFS/" '$3==r || index($3,d)==1 {f=1} END{exit !f}'; then
    echo "ERROR: active mount(s) at/under $ROOTFS — unmount before rebuilding:" >&2
    mount | awk -v r="$ROOTFS" -v d="$ROOTFS/" '$3==r || index($3,d)==1 {print "  sudo umount "$3}' >&2
    exit 1
fi

LOOP=""
cleanup() {
    # Belt-and-suspenders: drop the provision-time policy-rc.d shim in case
    # provision.sh was hard-killed before its own EXIT trap removed it — otherwise
    # the 'exit 101' shim would ship in the image and block every service start on
    # the device. Runs while $ROOTFS is still mounted; harmless if already gone.
    sudo rm -f "$ROOTFS/usr/sbin/policy-rc.d" 2>/dev/null || true
    # Restore the rootfs's own resolv.conf if we swapped in the host's.
    if [ -e "$ROOTFS/etc/resolv.conf.prov-bak" ]; then
        sudo rm -f "$ROOTFS/etc/resolv.conf"
        sudo mv "$ROOTFS/etc/resolv.conf.prov-bak" "$ROOTFS/etc/resolv.conf"
    fi
    sudo umount "$ROOTFS/boot/firmware" 2>/dev/null || true
    sudo umount "$ROOTFS/dev/pts" 2>/dev/null || true
    sudo umount "$ROOTFS/dev" 2>/dev/null || true
    sudo umount "$ROOTFS/sys" 2>/dev/null || true
    sudo umount "$ROOTFS/proc" 2>/dev/null || true
    sudo umount "$ROOTFS" 2>/dev/null || true
    [ -n "$LOOP" ] && sudo losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Decompressing stock image -> $OUT_IMG"
rm -f "$OUT_IMG"
xz -dc -T0 "$STOCK_XZ" > "$OUT_IMG"

echo "==> Growing image by ${GROW_MB} MiB and expanding root (p2)"
truncate -s "+${GROW_MB}M" "$OUT_IMG"
LOOP="$(sudo losetup -fP --show "$OUT_IMG")"
# Pi OS layout: p1 = boot firmware (FAT32, /boot/firmware), p2 = root (ext4).
sudo parted -s "$LOOP" resizepart 2 100%
sudo partprobe "$LOOP"
sudo e2fsck -fy "${LOOP}p2" || true
sudo resize2fs "${LOOP}p2"

echo "==> Mounting rootfs"
sudo mount "${LOOP}p2" "$ROOTFS"
sudo mkdir -p "$ROOTFS/boot/firmware"
sudo mount "${LOOP}p1" "$ROOTFS/boot/firmware"
sudo mount --bind /proc    "$ROOTFS/proc"
sudo mount --bind /sys     "$ROOTFS/sys"
sudo mount --bind /dev     "$ROOTFS/dev"
sudo mount --bind /dev/pts "$ROOTFS/dev/pts"

# Give the chroot working DNS for apt, but keep the rootfs's own file to restore so
# the host's resolv.conf isn't baked into the image (cleanup() puts it back).
sudo cp -a "$ROOTFS/etc/resolv.conf" "$ROOTFS/etc/resolv.conf.prov-bak" 2>/dev/null || true
sudo cp -f /etc/resolv.conf "$ROOTFS/etc/resolv.conf"

echo "==> Provisioning (arm64 chroot)"
export ROOTFS_DIR="$ROOTFS"
"$SCRIPT_DIR/provision.sh"

echo "==> Unmounting"
cleanup
LOOP=""
trap - EXIT

echo "==> Golden image ready: $OUT_IMG"
echo "    Flash it with: ./flash.sh <device>   (e.g. /dev/sda or /dev/mmcblk0)"
