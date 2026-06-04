#!/usr/bin/env bash
# Chroot-install the ARK-OS payload (MAVSDK + the ark-os-pi-<codename> deb) into a
# mounted Raspberry Pi OS rootfs. Runs only when build.sh is passed --provision; the
# target identity + hardware config are baked separately (and always) by
# configure_target.sh. Mirrors ark_jetson_kernel/provision.sh. Invoked by build.sh,
# which exports:
#   ROOTFS_DIR — absolute path to the mounted root partition
#   DOWNLOADS  — deb cache dir
# build.sh has already bind-mounted /proc /sys /dev and provided DNS; the
# qemu-aarch64 binfmt handler lets the chroot run arm64 maintainer scripts. /run is
# NOT mounted, so the ark-os postinst's runtime-only steps self-skip here and run on
# the device's first boot.
set -euo pipefail

: "${ROOTFS_DIR:?build.sh must export ROOTFS_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
DOWNLOADS="${DOWNLOADS:-$SCRIPT_DIR/downloads}"

# ARK-OS bakes the build-host OS codename into the package name (ark-os-<platform>-
# <codename>) and its preinst refuses to install on a different release — so the deb
# codename must match the base image. Derive it from PIOS_RELEASE: ark-os-pi-trixie
# here, from ARK-OS's trixie build (Debian 13 / python3.13).
ARK_OS_PKG="ark-os-pi-${PIOS_RELEASE}"
ARK_OS_DEB="${ARK_OS_PKG}_${ARK_OS_VERSION}_arm64.deb"
# MAVSDK has no debian13 (Trixie) arm64 asset — only debian13_amd64 — so on arm64 we use
# the debian12 (Bookworm) build. It's C++; libstdc++ is backward compatible, so it runs
# on Trixie. Bump to debian13_arm64 if MAVSDK ever ships one.
MAVSDK_DEB="libmavsdk-dev_${MAVSDK_VERSION}_debian12_arm64.deb"
ARK_OS_URL="https://github.com/ARK-Electronics/ARK-OS/releases/download/v${ARK_OS_VERSION}/${ARK_OS_DEB}"
MAVSDK_URL="https://github.com/mavlink/MAVSDK/releases/download/v${MAVSDK_VERSION}/${MAVSDK_DEB}"

in_chroot() { sudo chroot "$ROOTFS_DIR" "$@"; }

# Stage a deb into the rootfs /tmp, caching it under downloads/ first so a rebuild
# reuses it instead of re-downloading. A cache miss fetches the release asset into
# downloads/ (atomically via .partial); every path then copies from the cache into
# the rootfs /tmp, where apt installs it. Runs as the invoking user (downloads/ is
# user-owned); only the copy into the root-owned rootfs needs sudo.
stage_deb() {
    local deb="$1" url="$2"
    mkdir -p "$DOWNLOADS"
    if [ -f "$DOWNLOADS/$deb" ]; then
        echo "Using cached $deb"
    else
        echo "Downloading $deb -> downloads/"
        if ! curl -fL --retry 3 -o "$DOWNLOADS/$deb.partial" "$url"; then
            rm -f "$DOWNLOADS/$deb.partial"
            echo "ERROR: could not fetch $deb (not in $DOWNLOADS and $url failed)." >&2
            echo "       For an untagged CI build, drop the deb into $DOWNLOADS and set" >&2
            echo "       ARK_OS_VERSION in versions.env to its 0.0.0-<sha8>." >&2
            exit 1
        fi
        mv "$DOWNLOADS/$deb.partial" "$DOWNLOADS/$deb"
    fi
    sudo cp "$DOWNLOADS/$deb" "$ROOTFS_DIR/tmp/$deb"
}

# --- Block service (re)starts in the chroot. ark-os self-gates on
#     /run/systemd/system, but its deps (nginx, avahi, network-manager, …) do not. ---
printf '#!/bin/sh\nexit 101\n' | sudo tee "$ROOTFS_DIR/usr/sbin/policy-rc.d" >/dev/null
sudo chmod 0755 "$ROOTFS_DIR/usr/sbin/policy-rc.d"
trap 'sudo rm -f "$ROOTFS_DIR/usr/sbin/policy-rc.d"' EXIT

stage_deb "$MAVSDK_DEB" "$MAVSDK_URL"
stage_deb "$ARK_OS_DEB" "$ARK_OS_URL"

echo "==> apt-get update"
in_chroot apt-get update
echo "==> Installing MAVSDK (ark-os depends on libmavsdk-dev)"
in_chroot apt-get install -y "/tmp/$MAVSDK_DEB"
echo "==> Installing ${ARK_OS_PKG}"
in_chroot apt-get install -y "/tmp/$ARK_OS_DEB"

echo "==> Verifying packages are fully configured"
for pkg in libmavsdk-dev "$ARK_OS_PKG"; do
    status=$(in_chroot dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    [ "$status" = "install ok installed" ] || {
        echo "ERROR: $pkg is not installed (dpkg status: '${status:-missing}')." >&2
        exit 1
    }
done

echo "==> Cleaning apt cache and staged debs"
in_chroot apt-get clean
sudo rm -f "$ROOTFS_DIR/tmp/$MAVSDK_DEB" "$ROOTFS_DIR/tmp/$ARK_OS_DEB"

echo "==> ARK-OS payload installed"
