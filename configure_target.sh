#!/usr/bin/env bash
# Bake target identity + carrier hardware config into a mounted Raspberry Pi OS
# rootfs: the service account, hostname, config.txt overlays, and SSH. This always
# runs (with or without --provision) — it's what makes the image target-specific.
# The ARK-OS payload is installed separately by provision.sh (only with --provision).
#
# Invoked by build.sh, which exports:
#   ROOTFS_DIR — absolute path to the mounted root partition
#   TARGET     — build target (carrier × compute module)
# build.sh has already bind-mounted /proc /sys /dev; the qemu-aarch64 binfmt handler
# lets the chroot run arm64 commands. No packages are installed here, so this needs
# no policy-rc.d shim (nothing it does starts a service).
set -euo pipefail

: "${ROOTFS_DIR:?build.sh must export ROOTFS_DIR}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=versions.env
source "$SCRIPT_DIR/versions.env"

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

in_chroot() { sudo chroot "$ROOTFS_DIR" "$@"; }

# --- Bake the service account. Pi OS Lite ships no default user, but every ark-os
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

# config.txt lives on the firmware partition (build.sh mounts it at /boot/firmware,
# the location Trixie uses).
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

echo "==> Target configuration complete"
