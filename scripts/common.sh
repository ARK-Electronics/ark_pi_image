# shellcheck shell=bash
# Shared helpers for build.sh / flash.sh. Sourced after versions.env; expects REPO_DIR.

# Print every known target name (one per line), sorted.
list_targets() {
    local f
    for f in "$REPO_DIR"/targets/*.target; do
        [ -e "$f" ] || continue
        basename "${f%.target}"
    done | sort
}

# Print "name|description" for each target (description from TARGET_DESC if set).
list_targets_with_desc() {
    local f name desc
    for f in "$REPO_DIR"/targets/*.target; do
        [ -e "$f" ] || continue
        name="$(basename "${f%.target}")"
        # shellcheck source=/dev/null
        desc="$(TARGET_DESC=; source "$f" >/dev/null 2>&1; echo "${TARGET_DESC:-$name}")"
        printf '%s|%s\n' "$name" "$desc"
    done | sort
}

# Validate that $1 is a known target file. Exits on failure.
validate_target() {
    local name="$1"
    local file="$REPO_DIR/targets/${name}.target"
    if [ ! -f "$file" ]; then
        echo "ERROR: unknown target '$name' ($file not found). Available targets:" >&2
        list_targets | sed 's/^/  /' >&2
        exit 1
    fi
}

# Interactive numbered picker. Sets TARGET. Requires a TTY.
prompt_target() {
    local lines=() names=() i=1 choice
    if [ ! -t 0 ]; then
        echo "ERROR: no --target given and stdin is not a TTY (cannot prompt)." >&2
        echo "       Pass --target <name>. Available:" >&2
        list_targets | sed 's/^/  /' >&2
        exit 1
    fi
    mapfile -t lines < <(list_targets_with_desc)
    if [ "${#lines[@]}" -eq 0 ]; then
        echo "ERROR: no targets defined under targets/." >&2
        exit 1
    fi
    echo "Select target:"
    for line in "${lines[@]}"; do
        names+=("${line%%|*}")
        printf '  %d) %s — %s\n' "$i" "${line%%|*}" "${line#*|}"
        i=$((i + 1))
    done
    while true; do
        read -rp "Choice [1-${#names[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ]; then
            TARGET="${names[$((choice - 1))]}"
            return
        fi
        echo "  Invalid choice; enter a number 1-${#names[@]}."
    done
}

# Resolve TARGET from: explicit arg ($1), existing TARGET env, or interactive prompt.
# Call as: resolve_target "$_target_arg"
resolve_target() {
    local arg="${1:-}"
    if [ -n "$arg" ]; then
        TARGET="$arg"
    elif [ -z "${TARGET:-}" ]; then
        prompt_target
    fi
    # else: TARGET already set in the environment (non-interactive / CI)
    validate_target "$TARGET"
    export TARGET
}

# --- flash helpers ----------------------------------------------------------

# Print the whole disks (sda, nvme0n1, mmcblk0) that back the running system: every
# disk under the system mounts and active swap. findmnt -v drops a btrfs [/subvol]
# suffix, and lsblk -s walks up through partitions, LUKS and LVM to the disk.
system_disks() {
    local mp src
    {
        for mp in / /boot /boot/efi /boot/firmware /usr /var /home; do
            findmnt -nvo SOURCE --mountpoint "$mp" 2>/dev/null || true
        done
        swapon --noheadings --show=NAME 2>/dev/null || true
    } | while read -r src; do
        [ -b "$src" ] || continue
        lsblk -nsro NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { print $1 }'
    done | sort -u
}

# Echo candidate removable block devices (one path per line): non-empty USB disks and
# mmcblk cards, excluding the system disks and eMMC boot areas.
list_flash_candidates() {
    local sys name type size tran
    sys=" $(system_disks | tr '\n' ' ') "
    # TRAN last: it is empty for mmcblk, and read would shift the fields after it.
    while read -r name type size tran; do
        [ "$type" = disk ] || continue
        [ "${size:-0}" -gt 0 ] || continue
        [[ "$name" =~ mmcblk[0-9]+boot[0-9]+$ ]] && continue
        [[ "$sys" == *" ${name#/dev/} "* ]] && continue
        if [ "$tran" = "usb" ] || [[ "$name" == /dev/mmcblk* ]]; then
            printf '%s\n' "$name"
        fi
    done < <(lsblk -dpnbo NAME,TYPE,SIZE,TRAN 2>/dev/null)
}

# Resolve DEV: explicit arg, or (on a TTY) the sole removable candidate or a pick among many.
# Call as: resolve_flash_device "${1:-}"
resolve_flash_device() {
    local arg="${1:-}"
    local candidates=() c i=1 choice
    if [ -n "$arg" ]; then
        DEV="$arg"
        return
    fi
    mapfile -t candidates < <(list_flash_candidates)
    if [ "${#candidates[@]}" -eq 0 ]; then
        echo "ERROR: no removable USB/SD devices found." >&2
        echo "       Insert an SD card (or attach the CM via rpiboot) and re-run, or pass a device path." >&2
        exit 1
    fi
    if [ ! -t 0 ]; then
        echo "ERROR: no device given and stdin is not a TTY (cannot confirm a pick)." >&2
        echo "       Pass the device path explicitly. Candidates:" >&2
        for c in "${candidates[@]}"; do
            printf '  %s  (%s  %s)\n' "$c" "$(lsblk -dno SIZE "$c" | xargs)" "$(lsblk -dno MODEL "$c" 2>/dev/null | xargs || true)" >&2
        done
        exit 1
    fi
    if [ "${#candidates[@]}" -eq 1 ]; then
        DEV="${candidates[0]}"
        return
    fi
    echo "Multiple removable devices found:"
    for c in "${candidates[@]}"; do
        printf '  %d) %s  (%s  %s)\n' "$i" "$c" \
            "$(lsblk -dno SIZE "$c" | xargs)" \
            "$(lsblk -dno MODEL "$c" 2>/dev/null | xargs || echo unknown)"
        i=$((i + 1))
    done
    while true; do
        read -rp "Choice [1-${#candidates[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#candidates[@]}" ]; then
            DEV="${candidates[$((choice - 1))]}"
            return
        fi
        echo "  Invalid choice; enter a number 1-${#candidates[@]}."
    done
}
