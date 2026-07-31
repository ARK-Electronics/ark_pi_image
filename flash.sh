#!/usr/bin/env bash
# Write the built golden image to an SD card / USB device.
# Usage: ./flash.sh [--target <name>] [device]
#   No device → auto-detect the sole removable disk (or pick if several).
#   Confirms with y/N before writing — never requires re-typing the path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"
STAGING="$SCRIPT_DIR/staging"

_target_arg=""
_device_arg=""
while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            [ -n "${2:-}" ] || { echo "ERROR: --target requires a name (see --help)." >&2; exit 1; }
            _target_arg="$2"; shift 2
            ;;
        --target=*)
            _target_arg="${1#--target=}"; shift
            ;;
        -h|--help)
            echo "Usage: $0 [--target <name>] [device]"
            echo
            echo "  --target  carrier × module from targets/*.target (prompts if omitted)"
            echo "  device    block device to write (e.g. /dev/sda). If omitted, auto-detects"
            echo "            the sole removable USB/SD disk, or prompts when several are present."
            echo
            echo "Image resolution: staging/<target>-<codename>-ark-os.img if present, else"
            echo "staging/<target>-<codename>.img. Override with IMG=/path/to.img."
            echo
            echo "Available targets:"
            list_targets_with_desc | while IFS='|' read -r name desc; do
                printf '  %-14s %s\n' "$name" "$desc"
            done
            exit 0
            ;;
        -*)
            echo "ERROR: unknown option '$1' (see '$0 --help')." >&2
            exit 1
            ;;
        *)
            [ -z "$_device_arg" ] || { echo "ERROR: multiple device arguments ('$_device_arg', '$1')." >&2; exit 1; }
            _device_arg="$1"; shift
            ;;
    esac
done

# IMG= bypasses target/image resolution entirely (operator pointed at a specific file).
if [ -z "${IMG:-}" ]; then
    resolve_target "$_target_arg"
    if [ -f "$STAGING/${TARGET}-${PIOS_RELEASE}-ark-os.img" ]; then
        IMG="$STAGING/${TARGET}-${PIOS_RELEASE}-ark-os.img"
    else
        IMG="$STAGING/${TARGET}-${PIOS_RELEASE}.img"
    fi
elif [ -n "$_target_arg" ]; then
    echo "WARNING: IMG= is set; ignoring --target." >&2
fi

if [ ! -f "$IMG" ]; then
    echo "ERROR: image not found ($IMG)." >&2
    if [ -n "${TARGET:-}" ]; then
        echo "       Build it with ./build.sh --target $TARGET --provision, or set IMG= to pick another." >&2
    else
        echo "       Build an image with ./build.sh --target <name> --provision, or set IMG=." >&2
    fi
    if compgen -G "$STAGING/*.img" >/dev/null 2>&1; then
        echo "       Images present in staging/:" >&2
        for f in "$STAGING"/*.img; do echo "         $(basename "$f")" >&2; done
    fi
    exit 1
fi

resolve_flash_device "$_device_arg"

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
if [ -n "${TARGET:-}" ]; then
    echo "  target: $TARGET"
fi
read -rp "Proceed? [y/N] " confirm
case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 1 ;;
esac

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
