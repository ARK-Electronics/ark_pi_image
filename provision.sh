#!/usr/bin/env bash
# Chroot-install ARK-OS into a mounted Raspberry Pi OS rootfs. Mirrors
# ark_jetson_kernel/provision.sh. Invoked by build.sh, which exports:
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

# Load the build target (carrier × compute module). build.sh validates and exports
# TARGET; here we source its definition for the hostname + config.txt overlays to bake.
TARGET="${TARGET:?build.sh must export TARGET}"
TARGET_FILE="$SCRIPT_DIR/targets/$TARGET.target"
[ -f "$TARGET_FILE" ] || { echo "ERROR: unknown target '$TARGET' ($TARGET_FILE not found)." >&2; exit 1; }
# shellcheck source=/dev/null
source "$TARGET_FILE"
[ -z "${TARGET_STUB:-}" ] || { echo "ERROR: target '$TARGET' is a stub — populate $TARGET_FILE before building." >&2; exit 1; }
: "${TARGET_HOSTNAME:?target $TARGET must set TARGET_HOSTNAME}"
CONFIG_TXT_APPEND="${CONFIG_TXT_APPEND:-}"
declare -p CONFIG_TXT_DISABLE >/dev/null 2>&1 || CONFIG_TXT_DISABLE=()

ARK_OS_DEB="ark-os-pi_${ARK_OS_VERSION}_arm64.deb"
# Upstream publishes no ubuntu/raspbian asset; debian12_arm64 is a native match for
# Bookworm.
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

# --- Bake the service account. Bookworm ships no default user, but every ark-os
#     unit runs as User=$ARK_PI_USER, so it must exist before the deb installs. ---
if ! in_chroot getent passwd "$ARK_PI_USER" >/dev/null 2>&1; then
    echo "==> Creating '$ARK_PI_USER' user"
    in_chroot useradd -m -s /bin/bash "$ARK_PI_USER"
    echo "${ARK_PI_USER}:${ARK_PI_PASSWORD}" | in_chroot chpasswd
    in_chroot usermod -aG sudo "$ARK_PI_USER"
fi

# --- Bake target identity + carrier hardware config (hostname, config.txt, SSH) ---
echo "==> Applying target '$TARGET' (${TARGET_DESC:-$TARGET})"

# Hostname → avahi advertises <hostname>.local; the docs and ark-os service URLs use
# e.g. http://pi6x.local/.
echo "$TARGET_HOSTNAME" | sudo tee "$ROOTFS_DIR/etc/hostname" >/dev/null
if sudo grep -qE '^127\.0\.1\.1' "$ROOTFS_DIR/etc/hosts"; then
    sudo sed -i -E "s/^(127\.0\.1\.1[[:space:]]+).*/\1$TARGET_HOSTNAME/" "$ROOTFS_DIR/etc/hosts"
else
    printf '127.0.1.1\t%s\n' "$TARGET_HOSTNAME" | sudo tee -a "$ROOTFS_DIR/etc/hosts" >/dev/null
fi

# config.txt lives on the firmware partition (build.sh mounts it at /boot/firmware —
# the Bookworm/Trixie location; pre-Bookworm used /boot/config.txt).
CONFIG_TXT="$ROOTFS_DIR/boot/firmware/config.txt"
if [ -f "$CONFIG_TXT" ]; then
    if ((${#CONFIG_TXT_DISABLE[@]})); then
        for directive in "${CONFIG_TXT_DISABLE[@]}"; do
            # Comment the directive out if present and not already commented (idempotent).
            sudo sed -i -E "s|^([[:space:]]*)(${directive})[[:space:]]*\$|\1#\2|" "$CONFIG_TXT"
        done
    fi
    MARKER="# --- ARK-OS golden image ($TARGET) ---"
    if [ -n "$CONFIG_TXT_APPEND" ] && ! sudo grep -qF "$MARKER" "$CONFIG_TXT"; then
        printf '\n%s\n%s\n' "$MARKER" "$CONFIG_TXT_APPEND" | sudo tee -a "$CONFIG_TXT" >/dev/null
    fi
else
    echo "WARNING: $CONFIG_TXT not found — skipping config.txt edits." >&2
fi

# Enable SSH so the headless appliance is reachable on first boot. Prefer the
# deterministic systemctl path; fall back to the boot-partition flag (Pi OS enables
# ssh on first boot if /boot/firmware/ssh exists) if systemctl can't run in the chroot.
if [ "${ENABLE_SSH:-0}" = "1" ]; then
    echo "==> Enabling SSH"
    in_chroot systemctl enable ssh || sudo touch "$ROOTFS_DIR/boot/firmware/ssh"
fi

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
echo "==> Installing ark-os-pi"
in_chroot apt-get install -y "/tmp/$ARK_OS_DEB"

echo "==> Verifying packages are fully configured"
for pkg in libmavsdk-dev ark-os-pi; do
    status=$(in_chroot dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)
    [ "$status" = "install ok installed" ] || {
        echo "ERROR: $pkg is not installed (dpkg status: '${status:-missing}')." >&2
        exit 1
    }
done

echo "==> Cleaning apt cache and staged debs"
in_chroot apt-get clean
sudo rm -f "$ROOTFS_DIR/tmp/$MAVSDK_DEB" "$ROOTFS_DIR/tmp/$ARK_OS_DEB"

echo "==> provisioning complete"
