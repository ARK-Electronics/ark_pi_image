#!/usr/bin/env bash
# Chroot-install the ARK-OS payload (the ark-os-pi-<codename> deb) into the mounted
# rootfs. Runs only with --provision. build.sh exports ROOTFS_DIR + DOWNLOADS
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

# Keep downloaded dependency .debs in /var/cache/apt/archives (build.sh's persistent
# cache) instead of letting apt discard them, so the next build reuses them.
APT_INSTALL=(apt-get install -y -o APT::Keep-Downloaded-Packages=true)
echo "==> apt-get update"
in_chroot apt-get update
# MAVSDK is not installed separately: ark-os bundles its own under
# /usr/lib/ark-os/mavsdk (ARK-OS#75). A pre-bundling ark-os deb fails here with an
# unresolvable libmavsdk-dev Depends — fix by bumping ARK_OS_VERSION.
echo "==> Installing ${ARK_OS_PKG} ($ARK_OS_DEB)"
in_chroot "${APT_INSTALL[@]}" "/tmp/$ARK_OS_DEB"

echo "==> Verifying ${ARK_OS_PKG} is fully configured"
status=$(in_chroot dpkg-query -W -f='${Status}' "$ARK_OS_PKG" 2>/dev/null || true)
[ "$status" = "install ok installed" ] || {
    echo "ERROR: $ARK_OS_PKG is not installed (dpkg status: '${status:-missing}')." >&2
    exit 1
}
# The services load the MAVSDK bundled inside the deb; assert it shipped.
in_chroot sh -c 'ls /usr/lib/ark-os/mavsdk/lib/libmavsdk.so.* >/dev/null 2>&1' || {
    echo "ERROR: installed ark-os ships no bundled MAVSDK under /usr/lib/ark-os/mavsdk." >&2
    exit 1
}

# Don't `apt-get clean`: /var/cache/apt/archives is build.sh's persistent deb cache
# (bind-mounted from the host, unmounted before the image is finalized), so the
# downloaded debs are reused next build and never ship in the image. Just drop the
# staged payload deb from /tmp.
echo "==> Removing staged deb"
sudo rm -f "$ROOTFS_DIR/tmp/$ARK_OS_DEB"

echo "==> ARK-OS payload installed"
