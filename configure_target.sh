#!/usr/bin/env bash
# Bake target identity + carrier config into the mounted rootfs: service account,
# hostname, config.txt overlays, SSH, USB gadget. Always runs (the ARK-OS payload is
# separate, in provision.sh). build.sh exports ROOTFS_DIR + TARGET and has bind-mounted
# /proc /sys /dev; the qemu-aarch64 binfmt handler runs arm64 commands. Installs no
# packages, so no policy-rc.d.
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

# --- Service account. Pi OS Trixie ships a 'pi' user whose password is LOCKED — real
#     setup is deferred to a first-boot wizard that blocks SSH ("set up a valid user")
#     until it runs. Create the account if missing, then ALWAYS set its password + sudo
#     (a pre-existing locked 'pi' would otherwise ship with no usable login — guarding
#     chpasswd behind the create was the bug), and write userconf.txt so Pi OS's firstboot
#     treats the account as configured and cancels the wizard. ark-os also needs this
#     account: every unit runs as User=$ARK_PI_USER. ---
if ! in_chroot getent passwd "$ARK_PI_USER" >/dev/null 2>&1; then
    echo "==> Creating '$ARK_PI_USER' user"
    in_chroot useradd -m -s /bin/bash "$ARK_PI_USER"
fi
echo "==> Setting '$ARK_PI_USER' password + sudo"
echo "${ARK_PI_USER}:${ARK_PI_PASSWORD}" | in_chroot chpasswd
in_chroot usermod -aG sudo "$ARK_PI_USER"
printf '%s:%s\n' "$ARK_PI_USER" "$(openssl passwd -6 "$ARK_PI_PASSWORD")" \
    | sudo tee "$ROOTFS_DIR/boot/firmware/userconf.txt" >/dev/null

# --- Bake target identity + carrier hardware config (hostname, config.txt, SSH) ---
echo "==> Applying target '$TARGET' (${TARGET_DESC:-$TARGET})"

# Hostname → avahi advertises <hostname>.local (e.g. just-a-pi.local).
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

# Enable SSH; fall back to the boot-partition flag if systemctl can't run in the chroot.
if [ "${ENABLE_SSH:-0}" = "1" ]; then
    echo "==> Enabling SSH"
    in_chroot systemctl enable ssh || sudo touch "$ROOTFS_DIR/boot/firmware/ssh"
fi

# USB Ethernet gadget (Ethernet-over-USB on the dwc2 device port). Targets opt in with
# TARGET_USB_GADGET=1 and must also switch dwc2 to peripheral mode in their config.txt
# keys. Ships a configfs gadget script + oneshot unit + NM shared-mode profile; the kernel
# modules (dwc2, libcomposite, usb_f_ncm) and NM's dnsmasq-base are already in Pi OS.
if [ "${TARGET_USB_GADGET:-0}" = "1" ]; then
    echo "==> Installing USB Ethernet gadget"
    sudo install -D -m 0755 "$SCRIPT_DIR/files/usb-gadget/ark-usb-gadget" \
        "$ROOTFS_DIR/usr/local/sbin/ark-usb-gadget"
    sudo install -D -m 0644 "$SCRIPT_DIR/files/usb-gadget/ark-usb-gadget.service" \
        "$ROOTFS_DIR/etc/systemd/system/ark-usb-gadget.service"
    # NM refuses keyfiles unless they are 0600 root:root.
    sudo install -D -m 0600 -o root -g root "$SCRIPT_DIR/files/usb-gadget/ark-usb-gadget.nmconnection" \
        "$ROOTFS_DIR/etc/NetworkManager/system-connections/ark-usb-gadget.nmconnection"
    in_chroot systemctl enable ark-usb-gadget.service
fi

echo "==> Target configuration complete"
