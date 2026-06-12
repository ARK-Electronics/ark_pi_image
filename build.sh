#!/usr/bin/env bash
# Build a Raspberry Pi golden image: copy the stock image, grow its root partition,
# loop-mount it, bind-mount the kernel filesystems, and bake the target's hardware
# config in an arm64 chroot (configure_target.sh). With --provision it additionally
# installs the ARK-OS payload (provision.sh). Produces staging/<target>-<codename>.img,
# or staging/<target>-<codename>-ark-os.img when built with --provision.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
DOWNLOADS="$SCRIPT_DIR/downloads"
STAGING="$SCRIPT_DIR/staging"
export DOWNLOADS

# Format the bash SECONDS builtin as e.g. "14m 32s" for the final summary.
fmt_duration() {
    local s=$1 h m
    h=$(( s / 3600 )); m=$(( (s % 3600) / 60 )); s=$(( s % 60 ))
    if   (( h )); then printf '%dh %02dm %02ds' "$h" "$m" "$s"
    elif (( m )); then printf '%dm %02ds' "$m" "$s"
    else               printf '%ds' "$s"
    fi
}

# Bake provenance into the rootfs so each card self-documents what produced it. The image
# otherwise records only the ARK-OS deb version (via dpkg); this adds the builder commit,
# base-image sha, target, and build time. git_describe carries a '-dirty' suffix when the
# working tree had uncommitted changes at build time. Installed versions come from the
# rootfs dpkg DB (so dev-mode 0.0.0-<sha8> debs are recorded accurately).
write_image_manifest() {
    local describe commit branch built ark_os mavsdk provisioned
    built="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        describe="$(git -C "$SCRIPT_DIR" describe --tags --always --dirty 2>/dev/null || echo unknown)"
        commit="$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
        branch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    else
        describe=unknown; commit=unknown; branch=unknown
    fi
    if [ "$PROVISION" -eq 1 ]; then
        provisioned=true
        ark_os="\"$(sudo chroot "$ROOTFS" dpkg-query -W -f='${Version}' "ark-os-pi-${PIOS_RELEASE}" 2>/dev/null || echo unknown)\""
        mavsdk="\"$(sudo chroot "$ROOTFS" dpkg-query -W -f='${Version}' libmavsdk-dev 2>/dev/null || echo unknown)\""
    else
        provisioned=false; ark_os=null; mavsdk=null
    fi
    sudo tee "$ROOTFS/etc/ark-os-image.json" >/dev/null <<EOF
{
  "image": "$(basename "$OUT_IMG")",
  "target": "$TARGET",
  "built_utc": "$built",
  "base_image": { "release": "$PIOS_RELEASE", "sha256": "${PIOS_IMAGE_SHA256:-}" },
  "builder": { "repo": "ark_pi_image", "git_describe": "$describe", "git_commit": "$commit", "git_branch": "$branch" },
  "ark_os": { "provisioned": $provisioned, "version": $ark_os, "mavsdk": $mavsdk }
}
EOF
}

# Args: an optional target (default from versions.env) plus --provision, which adds the
# ARK-OS payload; without it the image is stock Pi OS + target config.
PROVISION=0
_target_arg=""
for arg in "$@"; do
    case "$arg" in
        --provision) PROVISION=1 ;;
        -h|--help)
            echo "Usage: $0 [target] [--provision]"
            echo "  target:      a name from targets/*.target (default from versions.env: $TARGET)"
            echo "  --provision: also install the ARK-OS payload (off by default)"
            exit 0
            ;;
        -*) echo "ERROR: unknown option '$arg' (see '$0 --help')." >&2; exit 1 ;;
        *)
            [ -z "$_target_arg" ] || { echo "ERROR: multiple targets given ('$_target_arg', '$arg')." >&2; exit 1; }
            _target_arg="$arg"
            ;;
    esac
done
TARGET="${_target_arg:-$TARGET}"
export TARGET
TARGET_FILE="$SCRIPT_DIR/targets/$TARGET.target"
[ -f "$TARGET_FILE" ] || {
    echo "ERROR: unknown target '$TARGET' ($TARGET_FILE not found). Available targets:" >&2
    for f in "$SCRIPT_DIR"/targets/*.target; do [ -e "$f" ] && echo "  $(basename "${f%.target}")" >&2; done
    exit 1
}
# Refuse to build a stub target (carrier/module specifics not defined yet).
if ( source "$TARGET_FILE" >/dev/null 2>&1; [ -n "${TARGET_STUB:-}" ] ); then
    echo "ERROR: target '$TARGET' is a stub — its specifics aren't defined yet." >&2
    echo "       Fill in $TARGET_FILE (see targets/justapi-cm5.target) and remove the TARGET_STUB line to build it." >&2
    exit 1
fi
# Tee all output (incl. configure_target.sh + provision.sh) to staging/build.log.txt.
mkdir -p "$STAGING"
exec > >(tee "$STAGING/build.log.txt") 2>&1

echo "==> Target: $TARGET"

sudo -v || { echo "ERROR: sudo is required to build a disk image." >&2; exit 1; }

# Delegate download + verification to setup.sh when the cached base image is missing or
# doesn't match the pinned sha256 (e.g. a cache left from a previous release).
STOCK_XZ="$DOWNLOADS/raspios-lite-arm64.img.xz"
stock_image_ok() {
    [ -f "$STOCK_XZ" ] || return 1
    [ -n "${PIOS_IMAGE_SHA256:-}" ] || return 0   # no pin to check against; trust the cache
    echo "$PIOS_IMAGE_SHA256  $STOCK_XZ" | sha256sum -c --status -
}
if ! stock_image_ok; then
    if [ -f "$STOCK_XZ" ]; then
        echo "==> Stock image doesn't match pinned sha256 (stale release?) — running setup.sh to refresh it"
    else
        echo "==> Stock image not present — running setup.sh to fetch it"
    fi
    "$SCRIPT_DIR/setup.sh"
    stock_image_ok || { echo "ERROR: stock image still missing or mismatched after setup.sh ($STOCK_XZ)." >&2; exit 1; }
fi

# -ark-os suffix marks a provisioned image.
if [ "$PROVISION" -eq 1 ]; then
    OUT_IMG="$STAGING/${TARGET}-${PIOS_RELEASE}-ark-os.img"
else
    OUT_IMG="$STAGING/${TARGET}-${PIOS_RELEASE}.img"
fi
ROOTFS="$STAGING/rootfs"
mkdir -p "$STAGING" "$ROOTFS"

# A leaked bind mount under $ROOTFS from an interrupted run would make the steps below
# touch the host's /dev or /proc — refuse and let the operator unmount.
if mount | awk -v r="$ROOTFS" -v d="$ROOTFS/" '$3==r || index($3,d)==1 {f=1} END{exit !f}'; then
    echo "ERROR: active mount(s) at/under $ROOTFS — unmount before rebuilding:" >&2
    mount | awk -v r="$ROOTFS" -v d="$ROOTFS/" '$3==r || index($3,d)==1 {print "  sudo umount "$3}' >&2
    exit 1
fi

LOOP=""
cleanup() {
    # Drop provision.sh's policy-rc.d shim in case it was hard-killed before its own
    # trap fired — otherwise the 'exit 101' shim ships and blocks every service start.
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
# Wait for udev to recreate ${LOOP}p2 after the partition-table change before fscking it;
# otherwise e2fsck/resize2fs can race the device node on a freshly resized partition.
sudo udevadm settle 2>/dev/null || true
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

export ROOTFS_DIR="$ROOTFS"
echo "==> Configuring target (arm64 chroot)"
"$SCRIPT_DIR/configure_target.sh"
if [ "$PROVISION" -eq 1 ]; then
    echo "==> Installing ARK-OS payload (arm64 chroot)"
    "$SCRIPT_DIR/provision.sh"
else
    echo "==> Skipping ARK-OS payload (no --provision; pass --provision to install it)"
fi

echo "==> Writing image manifest (/etc/ark-os-image.json)"
write_image_manifest

echo "==> Unmounting"
cleanup
LOOP=""
trap - EXIT

echo "==> Golden image ready in $(fmt_duration "$SECONDS"): $OUT_IMG"
echo "    Flash it with: ./flash.sh <device>   (e.g. /dev/sda or /dev/mmcblk0)"
