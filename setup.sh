#!/usr/bin/env bash
# Install host build dependencies and download the stock Raspberry Pi OS image.
# Run once per workstation, and again whenever versions.env's base image changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
DOWNLOADS="$SCRIPT_DIR/downloads"
mkdir -p "$DOWNLOADS"

# Tee all output to staging/setup.log.txt so a failed run can be inspected afterward.
mkdir -p "$SCRIPT_DIR/staging"
exec > >(tee "$SCRIPT_DIR/staging/setup.log.txt") 2>&1

[ "$(uname -s)" = "Linux" ] || { echo "ERROR: this builds Linux disk images; run it on Linux." >&2; exit 1; }

echo "==> Installing host dependencies (sudo)"
sudo apt-get update
sudo apt-get install -y \
    qemu-user-static binfmt-support \
    parted dosfstools e2fsprogs \
    xz-utils curl ca-certificates openssl

# Register the aarch64 binfmt handler so the chroot's arm64 binaries run on an x86 host.
# update-binfmts uses the fix-binary (F) flag, so qemu works in chroots without copying
# it in. Not needed on a native arm64 host.
if [ "$(uname -m)" != "aarch64" ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "==> Registering qemu-aarch64 binfmt handler"
    sudo update-binfmts --enable qemu-aarch64
fi

# Download the stock image. The cache filename is release-agnostic, so re-download when a
# pinned sha256 doesn't match the cached file (e.g. a leftover from a previous release).
IMG_XZ="$DOWNLOADS/raspios-lite-arm64.img.xz"
if [ -f "$IMG_XZ" ] && [ -n "${PIOS_IMAGE_SHA256:-}" ] \
   && ! echo "$PIOS_IMAGE_SHA256  $IMG_XZ" | sha256sum -c --status -; then
    echo "==> Cached image doesn't match the pinned sha256 (stale release?) — re-downloading"
    rm -f "$IMG_XZ"
fi
if [ -f "$IMG_XZ" ]; then
    echo "==> Stock image already cached: $IMG_XZ"
else
    echo "==> Downloading Raspberry Pi OS Lite (arm64, $PIOS_RELEASE)"
    curl -fL --retry 3 -o "$IMG_XZ.partial" "$PIOS_IMAGE_URL"
    mv "$IMG_XZ.partial" "$IMG_XZ"
fi

if [ -n "${PIOS_IMAGE_SHA256:-}" ]; then
    echo "==> Verifying sha256"
    echo "$PIOS_IMAGE_SHA256  $IMG_XZ" | sha256sum -c -
else
    echo "WARNING: PIOS_IMAGE_SHA256 is unset — skipping integrity check."
    echo "         Pin a dated image + its sha256 in versions.env for production."
fi

echo "==> setup complete. Next: ./build.sh --provision   (omit --provision for a stock + target-config image, no ARK-OS)"
