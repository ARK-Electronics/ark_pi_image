#!/usr/bin/env bash
# Build the target's out-of-tree kernel drivers (drivers/<name>/, listed in TARGET_DRIVERS)
# into the mounted rootfs with DKMS, for every kernel the image carries headers for, and
# compile each driver's device tree overlay into /boot/firmware/overlays. DKMS rebuilds the
# drivers whenever apt installs a new kernel. build.sh exports ROOTFS_DIR + TARGET, has
# bind-mounted /proc /sys /dev and the apt cache, and provided DNS; the qemu-aarch64 binfmt
# handler runs the arm64 compiler.
set -euo pipefail

: "${ROOTFS_DIR:?build.sh must export ROOTFS_DIR}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${TARGET:?build.sh must export TARGET}"
# shellcheck source=/dev/null
source "$REPO_DIR/targets/$TARGET.target"
declare -p TARGET_DRIVERS >/dev/null 2>&1 || TARGET_DRIVERS=()
if ((${#TARGET_DRIVERS[@]} == 0)); then
    echo "==> No drivers for $TARGET"
    exit 0
fi

in_chroot() { sudo chroot "$ROOTFS_DIR" "$@"; }

# Pi OS ships gcc, make, dtc and every kernel's headers; DKMS is the one addition. Keep the
# .deb in build.sh's persistent apt cache rather than letting apt discard it.
echo "==> Installing DKMS"
in_chroot apt-get update
in_chroot apt-get install -y -o APT::Keep-Downloaded-Packages=true dkms

for driver in "${TARGET_DRIVERS[@]}"; do
    source_dir="$REPO_DIR/drivers/$driver"
    version="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"$/\1/p' "$source_dir/dkms.conf")"
    [ -n "$version" ] || { echo "ERROR: no PACKAGE_VERSION in $source_dir/dkms.conf" >&2; exit 1; }

    echo "==> Building $driver $version with DKMS"
    # A rerun on the same rootfs rebuilds from the current sources rather than keep stale modules.
    if [ -n "$(in_chroot dkms status -m "$driver" -v "$version")" ]; then
        in_chroot dkms remove -m "$driver" -v "$version" --all
    fi
    sudo rm -rf "$ROOTFS_DIR/usr/src/$driver-$version"
    sudo install -d "$ROOTFS_DIR/usr/src/$driver-$version"
    sudo cp "$source_dir"/dkms.conf "$source_dir"/Makefile "$source_dir"/*.c "$source_dir"/*.h \
        "$ROOTFS_DIR/usr/src/$driver-$version/"
    in_chroot dkms add -m "$driver" -v "$version"
    # build is an absolute symlink into the rootfs's /usr/src, so test it from inside.
    for kernel in $(ls "$ROOTFS_DIR/lib/modules"); do
        if in_chroot test -e "/lib/modules/$kernel/build"; then
            in_chroot dkms install -m "$driver" -v "$version" -k "$kernel"
        else
            echo "    $kernel has no headers; skipped"
        fi
    done

    echo "==> Installing overlay $driver.dtbo"
    sudo cp "$source_dir/$driver-overlay.dts" "$ROOTFS_DIR/tmp/"
    in_chroot dtc -@ -q -I dts -O dtb -o "/boot/firmware/overlays/$driver.dtbo" "/tmp/$driver-overlay.dts"
    sudo rm -f "$ROOTFS_DIR/tmp/$driver-overlay.dts"
done

echo "==> Drivers installed: ${TARGET_DRIVERS[*]}"
