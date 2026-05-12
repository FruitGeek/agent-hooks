# Shared telemetry utilities for agent-hooks.
# Source this file; it defines functions only and has no side effects.
#
# Writes JSONL telemetry events to disk for the 1Password app to ingest.
# All functions fail silently — telemetry must never affect hook decisions.

[[ -n "${_LIB_TELEMETRY_LOADED:-}" ]] && return 0
_LIB_TELEMETRY_LOADED=1

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_LIB_DIR}/logging.sh"
source "${_LIB_DIR}/json.sh"

# Convert raw milliseconds to a bucketed range string
bucket_duration_ms() {
    local ms="${1:-0}"
    if [[ "$ms" -lt 50 ]]; then echo "0-50"
    elif [[ "$ms" -lt 100 ]]; then echo "50-100"
    elif [[ "$ms" -lt 200 ]]; then echo "100-200"
    elif [[ "$ms" -lt 500 ]]; then echo "200-500"
    elif [[ "$ms" -lt 1000 ]]; then echo "500-1000"
    elif [[ "$ms" -lt 5000 ]]; then echo "1000-5000"
    else echo "5000+"
    fi
}

get_telemetry_dir() {
    echo "${HOME}/.config/1Password/data/hook-events"
}

# Check whether the 1Password app has signaled that telemetry is enabled.
# Returns 0 (true) if the signal file exists, 1 (false) otherwise.
telemetry_consent_enabled() {
    [[ -f "${HOME}/.config/1Password/telemetry-enabled" ]]
}

# Append a single JSON line to the events.jsonl file.
# Checks consent and enforces a 1MB file size cap.
write_telemetry_event() {
    local json_line="$1"
    local event_dir
    event_dir=$(get_telemetry_dir)

    if ! telemetry_consent_enabled; then
        return 0
    fi

    mkdir -p "$event_dir" 2>/dev/null || return 0

    local event_file="${event_dir}/events.jsonl"

    # 1MB file size cap (~4100 events)
    if [[ -f "$event_file" ]]; then
        local file_size
        file_size=$(stat -f%z "$event_file" 2>/dev/null || stat -c%s "$event_file" 2>/dev/null || echo "0")
        if [[ "$file_size" -gt 1048576 ]]; then
            log "Telemetry file exceeds 1MB, skipping write"
            return 0
        fi
    fi

    printf '%s\n' "$json_line" >> "$event_file" 2>/dev/null || true
}

# Write an agent_hook_execution telemetry event.
write_execution_event() {
    local hook_name="$1"
    local hook_version="$2"
    local client="$3"
    local event_type="$4"
    local decision="$5"
    local deny_reason="$6"
    local duration_bucket="$7"
    local mode="$8"
    local mount_count="$9"

    local escaped_hook_name escaped_hook_version escaped_client escaped_event_type
    escaped_hook_name=$(escape_json_string "$hook_name")
    escaped_hook_version=$(escape_json_string "$hook_version")
    escaped_client=$(escape_json_string "$client")
    escaped_event_type=$(escape_json_string "$event_type")

    local deny_reason_json
    if [[ -z "$deny_reason" ]]; then
        deny_reason_json="null"
    else
        deny_reason_json="\"${deny_reason}\""
    fi

    local json_line
    json_line="{\"schema\":\"agent_hook_execution\",\"hook_name\":\"${escaped_hook_name}\",\"hook_version\":\"${escaped_hook_version}\",\"client\":\"${escaped_client}\",\"event_type\":\"${escaped_event_type}\",\"decision\":\"${decision}\",\"deny_reason\":${deny_reason_json},\"duration_ms\":\"${duration_bucket}\",\"mode\":\"${mode}\",\"mount_count\":${mount_count}}"

    write_telemetry_event "$json_line"
}

# Write an agent_hook_install telemetry event.
write_install_event() {
    local client="$1"
    local hook_name="$2"
    local install_method="$3"

    local escaped_client escaped_hook_name
    escaped_client=$(escape_json_string "$client")
    escaped_hook_name=$(escape_json_string "$hook_name")

    local json_line
    json_line="{\"schema\":\"agent_hook_install\",\"client\":\"${escaped_client}\",\"hook_name\":\"${escaped_hook_name}\",\"install_method\":\"${install_method}\"}"

    write_telemetry_event "$json_line"
}

# Write an install event on first execution per client+hook combination.
# Uses a sentinel file to avoid reporting duplicate events per install via plugin marketplace
check_install_sentinel() {
    local client="$1"
    local hook_name="$2"
    local install_method="$3"
    local event_dir
    event_dir=$(get_telemetry_dir)

    if ! telemetry_consent_enabled; then
        return 0
    fi

    mkdir -p "$event_dir" 2>/dev/null || return 0

    local sentinel="${event_dir}/.installed-${client}-${hook_name}-${install_method}"
    if [[ ! -f "$sentinel" ]]; then
        write_install_event "$client" "$hook_name" "$install_method"
        touch "$sentinel" 2>/dev/null || true
    fi
}

# Detect how the hook was deployed: plugin marketplace or install script.
# Pass the caller's SCRIPT_DIR as the argument.
detect_install_method() {
    local caller_dir="${1:-}"

    # Primary: IDE-provided plugin env vars (authoritative)
    # Covers Cursor, Claude Code, and GitHub Copilot (which reuses CLAUDE_PLUGIN_ROOT)
    if [[ -n "${CURSOR_PLUGIN_ROOT:-}" ]] || [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
        echo "plugin_marketplace"
        return 0
    fi

    # Secondary: Bundle directory naming convention from install.sh
    if [[ -n "$caller_dir" ]] && [[ "$caller_dir" == *"-1password-hooks-bundle"* ]]; then
        echo "install_script"
        return 0
    fi

    echo "unknown"
}
