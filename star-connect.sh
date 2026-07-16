#!/usr/bin/env bash

# Star Labs External Display Diagnostics
# Version 0.2
#
# Read-only diagnostic utility for external display, USB-C dock,
# DisplayPort, HDMI and EDID issues.
#
# The onscreen output provides a concise human-readable assessment.
# Full technical information is written to a report file.

set -u

SCRIPT_VERSION="0.2"
TIMESTAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
REPORT_FILE="${HOME}/external-display-diagnostics-${TIMESTAMP}.txt"
TECHNICAL_FILE="$(mktemp)"

trap 'rm -f "$TECHNICAL_FILE"' EXIT

if [[ -t 1 ]]; then
    BOLD="\033[1m"
    DIM="\033[2m"
    RED="\033[31m"
    GREEN="\033[32m"
    YELLOW="\033[33m"
    BLUE="\033[34m"
    RESET="\033[0m"
else
    BOLD=""
    DIM=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    RESET=""
fi

declare -a PASSES=()
declare -a WARNINGS=()
declare -a FAILURES=()
declare -a ACTIONS=()
declare -a CONNECTED_EXTERNAL=()

EXTERNAL_DISPLAY_FOUND=0
INTERNAL_DISPLAY_FOUND=0
EDID_FAILURE_FOUND=0
FALLBACK_MODE_FOUND=0
LIMITED_MODES_FOUND=0
VALID_EDID_FOUND=0
USB_DOCK_FOUND=0
DRIVER_FOUND=0

print_header() {
    clear 2>/dev/null || true

    printf '%b\n' "${BOLD}"
    printf '%s\n' "============================================================"
    printf '%s\n' "         Star Labs External Display Diagnostics"
    printf '%s\n' "                        v${SCRIPT_VERSION}"
    printf '%s\n' "============================================================"
    printf '%b\n' "${RESET}"
}

heading() {
    printf '\n%b%s%b\n' "${BOLD}${BLUE}" "$1" "${RESET}"
    printf '%s\n' "------------------------------------------------------------"
}

pass() {
    PASSES+=("$1")
}

warn() {
    WARNINGS+=("$1")
}

fail() {
    FAILURES+=("$1")
}

add_action() {
    local action="$1"
    local existing

    for existing in "${ACTIONS[@]:-}"; do
        [[ "$existing" == "$action" ]] && return
    done

    ACTIONS+=("$action")
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

is_external_connector() {
    case "$1" in
        *eDP*|*LVDS*|*DSI*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

record_technical() {
    printf '%s\n' "$*" >> "$TECHNICAL_FILE"
}

collect_system_information() {
    {
        printf '%s\n' "SYSTEM INFORMATION"
        printf '%s\n' "=================="
        printf 'Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf 'Hostname: %s\n' "$(hostname 2>/dev/null || echo Unknown)"
        printf 'User: %s\n' "${USER:-Unknown}"
        printf 'Kernel: %s\n' "$(uname -r)"
        printf 'Session type: %s\n' "${XDG_SESSION_TYPE:-Unknown}"
        printf 'Desktop: %s\n' "${XDG_CURRENT_DESKTOP:-Unknown}"
        printf 'Display variable: %s\n' "${DISPLAY:-Not set}"
        printf 'Wayland display: %s\n' "${WAYLAND_DISPLAY:-Not set}"

        if [[ -r /etc/os-release ]]; then
            (
                . /etc/os-release
                printf 'Operating system: %s\n' "${PRETTY_NAME:-Unknown}"
            )
        fi

        printf '\n'
    } >> "$TECHNICAL_FILE"

    case "${XDG_SESSION_TYPE:-unknown}" in
        wayland)
            pass "Wayland desktop session detected."
            ;;
        x11)
            pass "X11 desktop session detected."
            ;;
        *)
            warn "The desktop session type could not be identified."
            ;;
    esac
}

collect_gpu_information() {
    {
        printf '%s\n' "GRAPHICS HARDWARE"
        printf '%s\n' "================="
    } >> "$TECHNICAL_FILE"

    if command_exists lspci; then
        local gpu_output

        gpu_output="$(
            lspci -nnk 2>/dev/null |
                grep -A4 -Ei 'VGA compatible controller|3D controller|Display controller' ||
                true
        )"

        printf '%s\n\n' "$gpu_output" >> "$TECHNICAL_FILE"

        if [[ -n "$gpu_output" ]]; then
            DRIVER_FOUND=1
            pass "Graphics hardware and driver were detected."
        else
            warn "Graphics hardware could not be identified."
        fi
    else
        warn "The pciutils package is not installed."
        record_technical "lspci unavailable"
        record_technical ""
    fi

    if command_exists glxinfo; then
        {
            printf '%s\n' "OPENGL INFORMATION"
            printf '%s\n' "=================="
            glxinfo -B 2>/dev/null || true
            printf '\n'
        } >> "$TECHNICAL_FILE"
    fi
}

analyse_connector_edid() {
    local connector_path="$1"
    local connector_name="$2"
    local edid_file="${connector_path}/edid"
    local edid_size=0

    if [[ -r "$edid_file" ]]; then
        edid_size="$(wc -c < "$edid_file" 2>/dev/null || echo 0)"
    fi

    record_technical "EDID size: ${edid_size} bytes"

    if [[ "$edid_size" -eq 0 ]]; then
        EDID_FAILURE_FOUND=1
        fail "${connector_name}: monitor identification data could not be read."

        add_action "Power-cycle the dock by disconnecting power and USB-C for at least 30 seconds."
        add_action "Try another DisplayPort or HDMI cable."
        add_action "Set the monitor's DisplayPort mode to DP 1.2 temporarily."
        add_action "Test the display directly from the laptop where possible."

        return
    fi

    if (( edid_size % 128 != 0 )); then
        warn "${connector_name}: unusual EDID size of ${edid_size} bytes."
        add_action "Try another display cable and power-cycle the dock."
        return
    fi

    VALID_EDID_FOUND=1
    pass "${connector_name}: monitor identification data was read successfully."

    if command_exists edid-decode; then
        {
            printf '%s\n' "Decoded EDID:"
            edid-decode "$edid_file" 2>&1 || true
        } >> "$TECHNICAL_FILE"
    else
        record_technical "edid-decode is not installed."
    fi
}

analyse_connector_modes() {
    local connector_path="$1"
    local connector_name="$2"
    local modes_file="${connector_path}/modes"
    local modes=""
    local mode_count=0

    if [[ -r "$modes_file" ]]; then
        modes="$(cat "$modes_file" 2>/dev/null || true)"
    fi

    mode_count="$(
        printf '%s\n' "$modes" |
            sed '/^[[:space:]]*$/d' |
            wc -l
    )"

    record_technical "Available modes:"
    printf '%s\n' "${modes:-None reported}" >> "$TECHNICAL_FILE"

    if [[ -z "$modes" ]]; then
        fail "${connector_name}: no usable display modes were reported."
        add_action "Check the monitor input selection and cable connection."
        add_action "Try another output on the dock."
        return
    fi

    if printf '%s\n' "$modes" | grep -qx '1024x768' &&
       [[ "$mode_count" -eq 1 ]]; then
        FALLBACK_MODE_FOUND=1
        fail "${connector_name}: only the fallback 1024x768 resolution is available."

        add_action "Try another DisplayPort or HDMI cable."
        add_action "Set the monitor's DisplayPort mode to DP 1.2 temporarily."
        add_action "Disable Adaptive-Sync, FreeSync, DSC and MST temporarily."
        return
    fi

    if [[ "$mode_count" -le 2 ]]; then
        LIMITED_MODES_FOUND=1
        warn "${connector_name}: only ${mode_count} display mode(s) were reported."
        add_action "Try another cable and monitor input."
    else
        pass "${connector_name}: ${mode_count} display modes were reported."
    fi
}

collect_connectors() {
    {
        printf '%s\n' "DRM DISPLAY CONNECTORS"
        printf '%s\n' "======================"
    } >> "$TECHNICAL_FILE"

    local connector_path
    local connector_name
    local status
    local found_connector=0

    shopt -s nullglob

    for connector_path in /sys/class/drm/card*-*/; do
        [[ -r "${connector_path}/status" ]] || continue

        found_connector=1
        connector_name="$(basename "$connector_path")"
        status="$(cat "${connector_path}/status" 2>/dev/null || echo unknown)"

        {
            printf '\nConnector: %s\n' "$connector_name"
            printf 'Status: %s\n' "$status"
        } >> "$TECHNICAL_FILE"

        [[ "$status" == "connected" ]] || continue

        if is_external_connector "$connector_name"; then
            EXTERNAL_DISPLAY_FOUND=1
            CONNECTED_EXTERNAL+=("$connector_name")

            analyse_connector_edid "$connector_path" "$connector_name"
            analyse_connector_modes "$connector_path" "$connector_name"
        else
            INTERNAL_DISPLAY_FOUND=1
            pass "Built-in display detected as ${connector_name}."
        fi
    done

    shopt -u nullglob

    record_technical ""

    if [[ "$found_connector" -eq 0 ]]; then
        fail "No Linux DRM display connectors were found."
    fi

    if [[ "$EXTERNAL_DISPLAY_FOUND" -eq 1 ]]; then
        pass "External display connection detected: ${CONNECTED_EXTERNAL[*]}."
    else
        fail "No connected external display was detected."

        add_action "Confirm that the monitor is powered on and set to the correct input."
        add_action "Reconnect the display cable and USB-C dock."
        add_action "Try another USB-C port if one is available."
    fi
}

collect_xrandr_information() {
    {
        printf '%s\n' "XRANDR INFORMATION"
        printf '%s\n' "=================="
    } >> "$TECHNICAL_FILE"

    if ! command_exists xrandr; then
        record_technical "xrandr is not installed."
        record_technical ""
        return
    fi

    if [[ -z "${DISPLAY:-}" ]]; then
        record_technical "DISPLAY is not set."
        record_technical ""
        return
    fi

    {
        xrandr --query 2>&1 || true
        printf '\n'
        xrandr --verbose 2>&1 || true
        printf '\n'
    } >> "$TECHNICAL_FILE"
}

collect_usb_information() {
    {
        printf '%s\n' "USB DEVICES"
        printf '%s\n' "==========="
    } >> "$TECHNICAL_FILE"

    if command_exists lsusb; then
        local usb_output

        usb_output="$(lsusb 2>/dev/null || true)"
        printf '%s\n\n' "$usb_output" >> "$TECHNICAL_FILE"

        if printf '%s\n' "$usb_output" |
            grep -Eqi 'display|dock|hub|billboard|thunderbolt|usb.?c|synaptics|displaylink|realtek'; then
            USB_DOCK_FOUND=1
            pass "A possible USB-C dock, hub or display device was detected."
        else
            warn "No obvious USB-C dock was identified in the USB device list."
        fi
    else
        warn "The usbutils package is not installed."
        record_technical "lsusb unavailable"
        record_technical ""
    fi

    if command_exists boltctl; then
        {
            printf '%s\n' "THUNDERBOLT AND USB4"
            printf '%s\n' "===================="
            boltctl list 2>&1 || true
            printf '\n'
        } >> "$TECHNICAL_FILE"
    fi
}

collect_typec_information() {
    {
        printf '%s\n' "USB TYPE-C INFORMATION"
        printf '%s\n' "======================"
    } >> "$TECHNICAL_FILE"

    if compgen -G '/sys/class/typec/*' >/dev/null; then
        local typec_device
        local property

        for typec_device in /sys/class/typec/*; do
            printf '\n%s\n' "$(basename "$typec_device")" >> "$TECHNICAL_FILE"

            for property in data_role power_role port_type preferred_role; do
                if [[ -r "${typec_device}/${property}" ]]; then
                    printf '  %-16s %s\n' \
                        "${property}:" \
                        "$(cat "${typec_device}/${property}")" \
                        >> "$TECHNICAL_FILE"
                fi
            done
        done
    else
        record_technical "No USB Type-C class information was exposed."
    fi

    record_technical ""
}

collect_kernel_messages() {
    {
        printf '%s\n' "DISPLAY-RELATED KERNEL MESSAGES"
        printf '%s\n' "==============================="
    } >> "$TECHNICAL_FILE"

    local pattern
    pattern='drm|displayport|display port|edid|link train|link-training|aux|typec|type-c|thunderbolt|usb4|mst|dpcd'

    if dmesg >/dev/null 2>&1; then
        dmesg --color=never 2>/dev/null |
            grep -Ei "$pattern" |
            tail -n 300 >> "$TECHNICAL_FILE" || true
    elif command_exists journalctl; then
        sudo journalctl -k -b --no-pager 2>/dev/null |
            grep -Ei "$pattern" |
            tail -n 300 >> "$TECHNICAL_FILE" || true
    else
        record_technical "Kernel messages could not be accessed."
    fi

    record_technical ""
}

determine_primary_diagnosis() {
    if [[ "$EXTERNAL_DISPLAY_FOUND" -eq 0 ]]; then
        printf '%s\n' "The external display is not being detected by the Linux kernel."
        printf '\n%s\n' "Most likely causes:"
        printf '%s\n' \
            "  • Monitor set to the wrong input" \
            "  • Loose or faulty display cable" \
            "  • Dock not receiving power" \
            "  • USB-C connection does not support display output" \
            "  • Dock or adapter hardware fault"
        return
    fi

    if [[ "$EDID_FAILURE_FOUND" -eq 1 && "$FALLBACK_MODE_FOUND" -eq 1 ]]; then
        printf '%s\n' \
            "The external display is connected, but Linux cannot read its" \
            "identification data. The system has therefore selected the safe" \
            "fallback resolution of 1024x768."

        printf '\n%s\n' "Most likely issue:"
        printf '%s\n' \
            "  Display communication or DisplayPort link-training failure."

        printf '\n%s\n' "Common causes:"
        printf '%s\n' \
            "  • Faulty or marginal DisplayPort cable" \
            "  • Dock firmware or compatibility issue" \
            "  • Monitor DisplayPort mode incompatibility" \
            "  • Failed EDID communication through the dock"
        return
    fi

    if [[ "$EDID_FAILURE_FOUND" -eq 1 ]]; then
        printf '%s\n' \
            "The external display connection is present, but the monitor's" \
            "identification data could not be read."

        printf '\n%s\n' "Most likely issue:"
        printf '%s\n' \
            "  Cable, dock, adapter or DisplayPort communication failure."
        return
    fi

    if [[ "$FALLBACK_MODE_FOUND" -eq 1 ]]; then
        printf '%s\n' \
            "The external display is connected, but only the safe 1024x768" \
            "fallback resolution is available."

        printf '\n%s\n' "Most likely issue:"
        printf '%s\n' \
            "  Incomplete monitor mode detection or a display link problem."
        return
    fi

    if [[ "$LIMITED_MODES_FOUND" -eq 1 ]]; then
        printf '%s\n' \
            "The external display is connected, but it is reporting fewer" \
            "resolutions than expected."

        printf '\n%s\n' "Possible issue:"
        printf '%s\n' \
            "  Cable bandwidth, dock compatibility or monitor configuration."
        return
    fi

    if [[ "$VALID_EDID_FOUND" -eq 1 ]]; then
        printf '%s\n' \
            "The external display is detected and its identification data" \
            "appears valid. No obvious EDID failure was found."

        printf '\n%s\n' "If the screen remains blank, possible causes include:"
        printf '%s\n' \
            "  • Unsupported refresh rate" \
            "  • DisplayPort bandwidth limitation" \
            "  • DSC or MST compatibility" \
            "  • Desktop compositor or graphics driver issue"
        return
    fi

    printf '%s\n' \
        "The script did not identify a clear external display failure."
}

print_status_summary() {
    heading "Overall assessment"

    if [[ ${#FAILURES[@]} -gt 0 ]]; then
        printf '%bIssue detected%b\n\n' "${BOLD}${RED}" "${RESET}"
    elif [[ ${#WARNINGS[@]} -gt 0 ]]; then
        printf '%bPossible issue detected%b\n\n' "${BOLD}${YELLOW}" "${RESET}"
    else
        printf '%bNo obvious fault detected%b\n\n' "${BOLD}${GREEN}" "${RESET}"
    fi

    determine_primary_diagnosis
}

print_checks() {
    heading "Checks performed"

    local item

    for item in "${PASSES[@]}"; do
        printf '%b✓%b %s\n' "${GREEN}" "${RESET}" "$item"
    done

    for item in "${WARNINGS[@]}"; do
        printf '%b!%b %s\n' "${YELLOW}" "${RESET}" "$item"
    done

    for item in "${FAILURES[@]}"; do
        printf '%b✗%b %s\n' "${RED}" "${RESET}" "$item"
    done
}

print_actions() {
    heading "Recommended next steps"

    local number=1
    local action

    if [[ ${#ACTIONS[@]} -eq 0 ]]; then
        printf '%s\n' \
            "1. Confirm the correct display resolution and refresh rate in Settings." \
            "2. Test another cable if the problem continues." \
            "3. Review the technical report for driver or link-training errors."
        return
    fi

    for action in "${ACTIONS[@]}"; do
        printf '%d. %s\n' "$number" "$action"
        ((number++))
    done
}

write_report() {
    {
        printf '%s\n' "Star Labs External Display Diagnostics"
        printf 'Script version: %s\n' "$SCRIPT_VERSION"
        printf 'Generated: %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf '\n'

        printf '%s\n' "HUMAN-READABLE SUMMARY"
        printf '%s\n' "======================"
        printf '\n'

        if [[ ${#FAILURES[@]} -gt 0 ]]; then
            printf '%s\n' "Status: Issue detected"
        elif [[ ${#WARNINGS[@]} -gt 0 ]]; then
            printf '%s\n' "Status: Possible issue detected"
        else
            printf '%s\n' "Status: No obvious fault detected"
        fi

        printf '\n'
        determine_primary_diagnosis
        printf '\n'

        printf '%s\n' "Checks:"
        for item in "${PASSES[@]}"; do
            printf '  PASS: %s\n' "$item"
        done
        for item in "${WARNINGS[@]}"; do
            printf '  WARN: %s\n' "$item"
        done
        for item in "${FAILURES[@]}"; do
            printf '  FAIL: %s\n' "$item"
        done

        printf '\n%s\n' "Recommended actions:"
        local number=1
        local action

        for action in "${ACTIONS[@]}"; do
            printf '  %d. %s\n' "$number" "$action"
            ((number++))
        done

        printf '\n\n'
        cat "$TECHNICAL_FILE"
    } > "$REPORT_FILE"
}

main() {
    print_header

    printf '%s\n' "Checking the graphics system, display connection and monitor data..."

    collect_system_information
    collect_gpu_information
    collect_connectors
    collect_xrandr_information
    collect_usb_information
    collect_typec_information
    collect_kernel_messages

    write_report

    print_status_summary
    print_checks
    print_actions

    heading "Technical report"

    printf 'A full diagnostic report has been saved to:\n\n'
    printf '%b%s%b\n' "${BOLD}" "$REPORT_FILE" "${RESET}"

    printf '\nThe report includes:\n'
    printf '%s\n' \
        "  • Graphics hardware and driver information" \
        "  • Display connector states" \
        "  • Available resolutions" \
        "  • Monitor EDID data" \
        "  • USB-C and dock information" \
        "  • Display-related kernel messages" \
        "  • Full xrandr output"

    printf '\n'
}

main "$@"
