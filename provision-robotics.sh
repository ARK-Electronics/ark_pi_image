#!/usr/bin/env bash
# Chroot-install the opt-in robotics payload into the mounted rootfs. Runs only when
# build.sh is given --robotics and/or --hailo (it exports ROBOTICS/HAILO). Like
# provision.sh, build.sh has already bind-mounted /proc /sys /dev, provided DNS, and
# bind-mounted the persistent apt cache over /var/cache/apt/archives; the qemu-aarch64
# binfmt handler runs the arm64 maintainer scripts. /run is NOT mounted, so any service
# the debs ship stays installed-but-not-started and comes up on the device's first boot.
#
# What it installs (each gated independently):
#   ROBOTICS=1 -> OpenCV (Debian) + ROS 2 (community native Trixie debs, rospian repo)
#   HAILO=1    -> Hailo AI accelerator stack (Raspberry Pi's hailo-all metapackage)
#
# Nothing here is officially supported by ARK; ROS 2 in particular has no upstream
# Debian/Trixie packages (Debian is a Tier-3 platform), so this leans on a community
# build farm. Treat the resulting image as experimental until validated on hardware.
set -euo pipefail

: "${ROOTFS_DIR:?build.sh must export ROOTFS_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

ROBOTICS="${ROBOTICS:-0}"
HAILO="${HAILO:-0}"
if [ "$ROBOTICS" != "1" ] && [ "$HAILO" != "1" ]; then
    echo "==> provision-robotics.sh: nothing requested (ROBOTICS=$ROBOTICS HAILO=$HAILO); skipping."
    exit 0
fi

in_chroot() { sudo chroot "$ROOTFS_DIR" "$@"; }

# Keep downloaded dependency .debs in the (bind-mounted) apt cache instead of letting apt
# discard them, matching provision.sh so robotics and ARK-OS share one persistent cache.
APT_INSTALL=(apt-get install -y --no-install-recommends -o APT::Keep-Downloaded-Packages=true)

# --- Block service (re)starts in the chroot, exactly as provision.sh does: the debs
#     here (ROS 2, hailort) may ship units, and their dependencies (dbus, udev, …) start
#     services on install. A chroot has no init, so let none of them run now. ---
printf '#!/bin/sh\nexit 101\n' | sudo tee "$ROOTFS_DIR/usr/sbin/policy-rc.d" >/dev/null
sudo chmod 0755 "$ROOTFS_DIR/usr/sbin/policy-rc.d"
trap 'sudo rm -f "$ROOTFS_DIR/usr/sbin/policy-rc.d"' EXIT

# --- ROS 2 apt source ---
# Add the rospian repo (native ROS 2 Jazzy debs for Debian/Raspberry Pi OS Trixie) when
# ROS 2 is requested. apt's signed-by accepts an ASCII-armored key directly, so we fetch
# the .asc straight into the keyring dir — no gpg/dearmor step, nothing extra in the image.
# The source file is left in place so `apt install ros-jazzy-*` keeps working on device.
if [ "$ROBOTICS" = "1" ]; then
    : "${ROS2_APT_REPO:?versions.env must set ROS2_APT_REPO}"
    : "${ROS2_APT_SUITE:?versions.env must set ROS2_APT_SUITE}"
    : "${ROS2_APT_KEY_URL:?versions.env must set ROS2_APT_KEY_URL}"
    echo "==> Adding ROS 2 apt repo ($ROS2_APT_REPO $ROS2_APT_SUITE)"
    ROS2_KEYRING="$ROOTFS_DIR/usr/share/keyrings/rospian-archive-keyring.asc"
    sudo mkdir -p "$ROOTFS_DIR/usr/share/keyrings"
    if ! curl -fsSL --retry 3 "$ROS2_APT_KEY_URL" | sudo tee "$ROS2_KEYRING" >/dev/null; then
        echo "ERROR: could not fetch the ROS 2 signing key from $ROS2_APT_KEY_URL." >&2
        exit 1
    fi
    printf 'deb [arch=arm64 signed-by=/usr/share/keyrings/rospian-archive-keyring.asc] %s %s main\n' \
        "$ROS2_APT_REPO" "$ROS2_APT_SUITE" \
        | sudo tee "$ROOTFS_DIR/etc/apt/sources.list.d/rospian.list" >/dev/null
fi

echo "==> apt-get update"
in_chroot apt-get update

# --- OpenCV (Debian) ---
if [ "$ROBOTICS" = "1" ] && [ -n "${OPENCV_PACKAGES:-}" ]; then
    echo "==> Installing OpenCV ($OPENCV_PACKAGES)"
    # shellcheck disable=SC2086
    in_chroot "${APT_INSTALL[@]}" $OPENCV_PACKAGES
fi

# --- ROS 2 (rospian native Trixie debs) ---
if [ "$ROBOTICS" = "1" ]; then
    : "${ROS2_PACKAGE:?versions.env must set ROS2_PACKAGE}"
    echo "==> Installing ROS 2 ($ROS2_PACKAGE)"
    in_chroot "${APT_INSTALL[@]}" "$ROS2_PACKAGE"

    if [ -n "${ROS2_DEV_TOOLS:-}" ]; then
        echo "==> Installing ROS 2 dev tools ($ROS2_DEV_TOOLS)"
        # shellcheck disable=SC2086
        in_chroot "${APT_INSTALL[@]}" $ROS2_DEV_TOOLS
    fi

    # Source the ROS 2 environment for interactive logins, so `ros2 ...` just works on the
    # device without the user hunting for the setup script. Drop a profile snippet rather
    # than editing the user's ~/.bashrc (which the firstboot/user setup may rewrite).
    echo "==> Enabling ROS 2 environment for login shells (/etc/profile.d)"
    sudo tee "$ROOTFS_DIR/etc/profile.d/ros2.sh" >/dev/null <<EOF
# Auto-source ROS 2 ${ROS2_DISTRO}. Written by ark_pi_image provision-robotics.sh.
if [ -f /opt/ros/${ROS2_DISTRO}/setup.bash ]; then
    . /opt/ros/${ROS2_DISTRO}/setup.bash
fi
EOF

    echo "==> Verifying ROS 2 installed (/opt/ros/${ROS2_DISTRO})"
    in_chroot test -f "/opt/ros/${ROS2_DISTRO}/setup.bash" || {
        echo "ERROR: ROS 2 setup.bash not found under /opt/ros/${ROS2_DISTRO} after install." >&2
        exit 1
    }

    # Pre-seed the rosdep sources list offline so `rosdep update` works on first run; the
    # actual `rosdep init` writes /etc/ros/rosdep/sources.list.d/20-default.list. It needs
    # network and is harmless to skip here, so don't fail the build if it can't reach out.
    if in_chroot test -x /usr/bin/rosdep || in_chroot sh -c 'command -v rosdep >/dev/null 2>&1'; then
        echo "==> rosdep init (best effort)"
        in_chroot rosdep init 2>/dev/null || echo "    (rosdep already initialized or offline; run 'rosdep update' on device)"
    fi
fi

# --- Hailo AI accelerator (Raspberry Pi hailo-all) ---
if [ "$HAILO" = "1" ]; then
    : "${HAILO_PACKAGE:?versions.env must set HAILO_PACKAGE}"
    echo "==> Installing Hailo stack ($HAILO_PACKAGE)"
    # hailo-all lives in the Raspberry Pi apt repo already configured in the base image.
    # The hailo_pci driver is part of the Pi kernel, so this is userspace only (no DKMS
    # build against a kernel we don't have in the chroot).
    in_chroot "${APT_INSTALL[@]}" "$HAILO_PACKAGE"

    echo "==> Verifying Hailo stack installed"
    status=$(in_chroot dpkg-query -W -f='${Status}' "$HAILO_PACKAGE" 2>/dev/null || true)
    [ "$status" = "install ok installed" ] || {
        echo "ERROR: $HAILO_PACKAGE is not installed (dpkg status: '${status:-missing}')." >&2
        exit 1
    }
fi

# Don't `apt-get clean`: /var/cache/apt/archives is build.sh's persistent deb cache
# (bind-mounted from the host, unmounted before the image is finalized), so the
# downloaded debs are reused next build and never ship in the image.
echo "==> Robotics payload installed (robotics=$ROBOTICS hailo=$HAILO)"
