# shellcheck shell=bash
# Shared helpers for build.sh / flash.sh. Sourced after versions.env; expects SCRIPT_DIR.

# Print every known target name (one per line), sorted.
list_targets() {
    local f
    for f in "$SCRIPT_DIR"/targets/*.target; do
        [ -e "$f" ] || continue
        basename "${f%.target}"
    done | sort
}

# Print "name|description" for each target (description from TARGET_DESC if set).
list_targets_with_desc() {
    local f name desc
    for f in "$SCRIPT_DIR"/targets/*.target; do
        [ -e "$f" ] || continue
        name="$(basename "${f%.target}")"
        # shellcheck source=/dev/null
        desc="$(TARGET_STUB=; TARGET_DESC=; source "$f" >/dev/null 2>&1; echo "${TARGET_DESC:-$name}")"
        printf '%s|%s\n' "$name" "$desc"
    done | sort
}

# Validate that $1 is a known, non-stub target file. Exits on failure.
validate_target() {
    local name="$1"
    local file="$SCRIPT_DIR/targets/${name}.target"
    if [ ! -f "$file" ]; then
        echo "ERROR: unknown target '$name' ($file not found). Available targets:" >&2
        list_targets | sed 's/^/  /' >&2
        exit 1
    fi
    if ( source "$file" >/dev/null 2>&1; [ -n "${TARGET_STUB:-}" ] ); then
        echo "ERROR: target '$name' is a stub — its specifics aren't defined yet." >&2
        echo "       Fill in $file and remove the TARGET_STUB line to use it." >&2
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

# Echo candidate removable block devices (one path per line): USB disks and mmcblk,
# excluding the disk that holds the running root filesystem.
list_flash_candidates() {
    local root_src root_pk name tran pk
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    root_pk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)"
    # Fall back: if root is already a whole disk (no partition), PKNAME is empty.
    if [ -z "$root_pk" ] && [ -n "$root_src" ]; then
        root_pk="$(lsblk -no NAME "$root_src" 2>/dev/null | head -1 || true)"
    fi
    # NAME + TRAN only — MODEL can contain spaces and would break field splitting.
    while read -r name tran; do
        [ -n "$name" ] || continue
        pk="${name#/dev/}"
        if [ -n "$root_pk" ] && [ "$pk" = "$root_pk" ]; then
            continue
        fi
        # Prefer USB transports; also accept mmcblk (onboard SD readers).
        if [ "$tran" = "usb" ] || [[ "$pk" == mmcblk* ]]; then
            printf '%s\n' "$name"
        fi
    done < <(lsblk -dpno NAME,TRAN 2>/dev/null)
}

# Resolve DEV: explicit arg, sole removable candidate, or interactive pick among many.
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
    if [ "${#candidates[@]}" -eq 1 ]; then
        DEV="${candidates[0]}"
        return
    fi
    if [ ! -t 0 ]; then
        echo "ERROR: multiple removable devices and stdin is not a TTY (cannot prompt)." >&2
        echo "       Pass the device path explicitly. Candidates:" >&2
        for c in "${candidates[@]}"; do
            printf '  %s  (%s  %s)\n' "$c" "$(lsblk -dno SIZE "$c" | xargs)" "$(lsblk -dno MODEL "$c" 2>/dev/null | xargs || true)" >&2
        done
        exit 1
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
