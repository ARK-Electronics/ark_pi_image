#!/usr/bin/env bash
# Install host build dependencies and download the stock Raspberry Pi OS image.
# Run once per workstation, and again whenever versions.env's base image changes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
DOWNLOADS="$SCRIPT_DIR/downloads"
mkdir -p "$DOWNLOADS"

[ "$(uname -s)" = "Linux" ] || { echo "ERROR: this builds Linux disk images; run it on Linux." >&2; exit 1; }

echo "==> Installing host dependencies (sudo)"
sudo apt-get update
sudo apt-get install -y \
    qemu-user-static binfmt-support \
    parted dosfstools e2fsprogs \
    xz-utils curl ca-certificates

# Register the aarch64 binfmt handler so the arm64 rootfs's binaries (apt, dpkg,
# the deb maintainer scripts) run inside the chroot on an x86 host. update-binfmts
# uses the fix-binary (F) flag, so qemu is available in chroots without copying it
# in. Not needed on a native arm64 host.
if [ "$(uname -m)" != "aarch64" ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "==> Registering qemu-aarch64 binfmt handler"
    sudo update-binfmts --enable qemu-aarch64
fi

# Download the stock image into the cache (idempotent).
IMG_XZ="$DOWNLOADS/raspios-lite-arm64.img.xz"
if [ -f "$IMG_XZ" ]; then
    echo "==> Stock image already cached: $IMG_XZ"
else
    echo "==> Downloading Raspberry Pi OS Lite (arm64)"
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

echo "==> setup complete. Next: ./build.sh"
