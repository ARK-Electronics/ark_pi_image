#!/usr/bin/env bash
# Chroot-install the ARK-OS payload (MAVSDK + the ark-os-pi-<codename> deb) into the
# mounted rootfs. Runs only with --provision. build.sh exports ROOTFS_DIR + DOWNLOADS
# and has already bind-mounted /proc /sys /dev and provided DNS; the qemu-aarch64 binfmt
# handler runs the arm64 maintainer scripts. /run is NOT mounted, so the ark-os postinst's
# runtime-only steps self-skip here and run on the device's first boot.
set -euo pipefail

: "${ROOTFS_DIR:?build.sh must export ROOTFS_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"
DOWNLOADS="${DOWNLOADS:-$SCRIPT_DIR/downloads}"

# The codename is part of the package name and its preinst refuses a release mismatch,
# so this must track the base image (→ ark-os-pi-trixie).
ARK_OS_PKG="ark-os-pi-${PIOS_RELEASE}"
# No Trixie arm64 MAVSDK asset exists; the debian12 (Bookworm) build is C++ and libstdc++
# is backward compatible, so it runs on Trixie. Bump to debian13_arm64 if one ever ships.
MAVSDK_DEB="libmavsdk-dev_${MAVSDK_VERSION}_debian12_arm64.deb"
MAVSDK_URL="https://github.com/mavlink/MAVSDK/releases/download/v${MAVSDK_VERSION}/${MAVSDK_DEB}"

in_chroot() { sudo chroot "$ROOTFS_DIR" "$@"; }

# Copy a deb into the rootfs /tmp for apt to install, caching it in downloads/ first
# (a cache miss fetches the release asset atomically via .partial).
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

# Pick the ARK-OS deb when ARK_OS_VERSION is unset (development mode): the newest
# ark-os-pi-<codename>_*_arm64.deb in downloads/. Errors if none is present; if several
# have accumulated, warns and lists them (newest wins). Prints the chosen basename.
resolve_local_ark_os_deb() {
    local f newest="" matches=()
    for f in "$DOWNLOADS/${ARK_OS_PKG}"_*_arm64.deb; do
        [ -e "$f" ] || continue
        matches+=("$f")
        if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
    done
    if [ -z "$newest" ]; then
        echo "ERROR: ARK_OS_VERSION is unset and no ${ARK_OS_PKG}_*_arm64.deb is in $DOWNLOADS." >&2
        echo "       Drop an ARK-OS ${PIOS_RELEASE} deb there (an ARK-OS CI build artifact, or the" >&2
        echo "       output of ARK-OS's ./packaging/build.sh pi on a ${PIOS_RELEASE} host), or pin" >&2
        echo "       ARK_OS_VERSION in versions.env to a published release." >&2
        return 1
    fi
    if ((${#matches[@]} > 1)); then
        echo "WARNING: multiple ${ARK_OS_PKG} debs in $DOWNLOADS; using the newest:" >&2
        for f in "${matches[@]}"; do echo "           $(basename "$f")" >&2; done
    fi
    basename "$newest"
}

# --- Block service (re)starts in the chroot. ark-os self-gates on
#     /run/systemd/system, but its deps (nginx, avahi, network-manager, …) do not. ---
printf '#!/bin/sh\nexit 101\n' | sudo tee "$ROOTFS_DIR/usr/sbin/policy-rc.d" >/dev/null
sudo chmod 0755 "$ROOTFS_DIR/usr/sbin/policy-rc.d"
trap 'sudo rm -f "$ROOTFS_DIR/usr/sbin/policy-rc.d"' EXIT

stage_deb "$MAVSDK_DEB" "$MAVSDK_URL"

# Resolve the ARK-OS deb: pinned ARK_OS_VERSION fetches that release asset; unset is dev
# mode (newest matching deb in downloads/ — for CI artifacts that can't be fetched by version).
if [ -n "${ARK_OS_VERSION:-}" ]; then
    ARK_OS_DEB="${ARK_OS_PKG}_${ARK_OS_VERSION}_arm64.deb"
    ARK_OS_URL="https://github.com/ARK-Electronics/ARK-OS/releases/download/v${ARK_OS_VERSION}/${ARK_OS_DEB}"
    stage_deb "$ARK_OS_DEB" "$ARK_OS_URL"
else
    echo "WARNING: ARK_OS_VERSION is unset — using an unpinned ARK-OS deb from downloads/ (development mode)." >&2
    ARK_OS_DEB="$(resolve_local_ark_os_deb)" || exit 1
    echo "==> Using $ARK_OS_DEB"
    sudo cp "$DOWNLOADS/$ARK_OS_DEB" "$ROOTFS_DIR/tmp/$ARK_OS_DEB"
fi

echo "==> apt-get update"
in_chroot apt-get update
echo "==> Installing MAVSDK (ark-os depends on libmavsdk-dev)"
in_chroot apt-get install -y "/tmp/$MAVSDK_DEB"
echo "==> Installing ${ARK_OS_PKG} ($ARK_OS_DEB)"
in_chroot apt-get install -y "/tmp/$ARK_OS_DEB"

echo "==> Verifying packages are fully configured"
for pkg in libmavsdk-dev "$ARK_OS_PKG"; do
    status=$(in_chroot dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    [ "$status" = "install ok installed" ] || {
        echo "ERROR: $pkg is not installed (dpkg status: '${status:-missing}')." >&2
        exit 1
    }
done

# dpkg confirms the cross-release MAVSDK deb installed, but not that its versioned
# glibc/libstdc++ symbols are satisfied (no apt dep declares them). Catch a "version not
# found" load failure — the risk a MAVSDK_VERSION bump could introduce — before shipping.
echo "==> Checking MAVSDK ABI compatibility with the rootfs"
"$SCRIPT_DIR/check_mavsdk_abi.sh" "$ROOTFS_DIR"

echo "==> Cleaning apt cache and staged debs"
in_chroot apt-get clean
sudo rm -f "$ROOTFS_DIR/tmp/$MAVSDK_DEB" "$ROOTFS_DIR/tmp/$ARK_OS_DEB"

echo "==> ARK-OS payload installed"
