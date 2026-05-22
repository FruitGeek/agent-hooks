#!/usr/bin/env bats

load "../test_helper"

setup() {
    unset _LIB_TELEMETRY_LOADED _LIB_JSON_LOADED _LIB_LOGGING_LOADED _LIB_OS_LOADED

    # Use a temp HOME so we don't touch real config
    export ORIGINAL_HOME="$HOME"
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "$HOME"

    source "${LIB_DIR}/telemetry.sh"
}

teardown() {
    export HOME="$ORIGINAL_HOME"
}

# Helper: create the consent signal file
create_consent_signal() {
    mkdir -p "${HOME}/.config/1Password"
    touch "${HOME}/.config/1Password/telemetry-enabled"
}

# ========== bucket_duration_ms ==========

@test "bucket_duration_ms: 0 returns 0-50" {
    run bucket_duration_ms 0
    [[ "$output" == "0-50" ]]
}

@test "bucket_duration_ms: 49 returns 0-50" {
    run bucket_duration_ms 49
    [[ "$output" == "0-50" ]]
}

@test "bucket_duration_ms: 50 returns 50-100" {
    run bucket_duration_ms 50
    [[ "$output" == "50-100" ]]
}

@test "bucket_duration_ms: 99 returns 50-100" {
    run bucket_duration_ms 99
    [[ "$output" == "50-100" ]]
}

@test "bucket_duration_ms: 100 returns 100-200" {
    run bucket_duration_ms 100
    [[ "$output" == "100-200" ]]
}

@test "bucket_duration_ms: 500 returns 500-1000" {
    run bucket_duration_ms 500
    [[ "$output" == "500-1000" ]]
}

@test "bucket_duration_ms: 1000 returns 1000-5000" {
    run bucket_duration_ms 1000
    [[ "$output" == "1000-5000" ]]
}

@test "bucket_duration_ms: 5000 returns 5000+" {
    run bucket_duration_ms 5000
    [[ "$output" == "5000+" ]]
}

@test "bucket_duration_ms: 10000 returns 5000+" {
    run bucket_duration_ms 10000
    [[ "$output" == "5000+" ]]
}

@test "bucket_duration_ms: empty input returns 0-50" {
    run bucket_duration_ms ""
    [[ "$output" == "0-50" ]]
}

# ========== telemetry_consent_enabled ==========

@test "telemetry_consent_enabled: returns false when signal file absent" {
    run telemetry_consent_enabled
    [[ "$status" -ne 0 ]]
}

@test "telemetry_consent_enabled: returns true when signal file present" {
    create_consent_signal
    run telemetry_consent_enabled
    [[ "$status" -eq 0 ]]
}

# ========== write_telemetry_event ==========

@test "write_telemetry_event: writes a line to events.jsonl" {
    create_consent_signal
    write_telemetry_event '{"test":"value"}'
    local event_file
    event_file="$(get_telemetry_dir)/events.jsonl"
    [[ -f "$event_file" ]]
    [[ "$(cat "$event_file")" == '{"test":"value"}' ]]
}

@test "write_telemetry_event: no-op when consent absent" {
    write_telemetry_event '{"test":"value"}'
    local event_file
    event_file="$(get_telemetry_dir)/events.jsonl"
    [[ ! -f "$event_file" ]]
}

@test "write_telemetry_event: creates directory if missing" {
    create_consent_signal
    local event_dir
    event_dir="$(get_telemetry_dir)"
    [[ ! -d "$event_dir" ]]
    write_telemetry_event '{"test":"value"}'
    [[ -d "$event_dir" ]]
}

@test "write_telemetry_event: respects 1MB cap" {
    create_consent_signal
    local event_dir
    event_dir="$(get_telemetry_dir)"
    mkdir -p "$event_dir"
    local event_file="${event_dir}/events.jsonl"
    # Create a file just over 1MB
    dd if=/dev/zero of="$event_file" bs=1048577 count=1 2>/dev/null
    write_telemetry_event '{"should":"not appear"}'
    # File should still be ~1MB, not have our line appended
    ! grep -q "should" "$event_file"
}

@test "write_telemetry_event: appends multiple lines" {
    create_consent_signal
    write_telemetry_event '{"line":1}'
    write_telemetry_event '{"line":2}'
    write_telemetry_event '{"line":3}'
    local event_file
    event_file="$(get_telemetry_dir)/events.jsonl"
    local count
    count=$(wc -l < "$event_file" | tr -d ' ')
    [[ "$count" -eq 3 ]]
}

# ========== write_execution_event ==========

@test "write_execution_event: correct JSON structure" {
    create_consent_signal
    write_execution_event \
        "validate_mounted_env_files" \
        "0.1.0" \
        "cursor" \
        "before_shell_execution" \
        "allow" \
        "" \
        "42" \
        "configured" \
        "3"
    local event_file
    event_file="$(get_telemetry_dir)/events.jsonl"
    local line
    line=$(cat "$event_file")
    [[ "$line" == *'"schema":"agent_hook_execution"'* ]]
    [[ "$line" == *'"hook_name":"validate_mounted_env_files"'* ]]
    [[ "$line" == *'"hook_version":"0.1.0"'* ]]
    [[ "$line" == *'"client":"cursor"'* ]]
    [[ "$line" == *'"decision":"allow"'* ]]
    [[ "$line" == *'"deny_reason":null'* ]]
    [[ "$line" == *'"duration_ms":"0-50"'* ]]
    [[ "$line" != *'"duration_bucket"'* ]]
    [[ "$line" == *'"mode":"configured"'* ]]
    [[ "$line" == *'"mount_count":3'* ]]
}

@test "write_execution_event: deny_reason is set when provided" {
    create_consent_signal
    write_execution_event \
        "validate_mounted_env_files" \
        "0.1.0" \
        "cursor" \
        "before_shell_execution" \
        "deny" \
        "file_missing" \
        "1234" \
        "default" \
        "1"
    local event_file
    event_file="$(get_telemetry_dir)/events.jsonl"
    local line
    line=$(cat "$event_file")
    [[ "$line" == *'"deny_reason":"file_missing"'* ]]
    [[ "$line" == *'"decision":"deny"'* ]]
    [[ "$line" == *'"duration_ms":"1000-5000"'* ]]
    [[ "$line" != *'"duration_bucket"'* ]]
}

# ========== write_install_event ==========

@test "write_install_event: correct JSON structure" {
    create_consent_signal
    write_install_event "cursor" "validate_mounted_env_files" "install_script"
    local event_file
    event_file="$(get_telemetry_dir)/events.jsonl"
    local line
    line=$(cat "$event_file")
    [[ "$line" == *'"schema":"agent_hook_install"'* ]]
    [[ "$line" == *'"client":"cursor"'* ]]
    [[ "$line" == *'"hook_name":"validate_mounted_env_files"'* ]]
    [[ "$line" == *'"install_method":"install_script"'* ]]
}

# ========== check_install_sentinel ==========

@test "check_install_sentinel: creates sentinel and writes event on first call" {
    create_consent_signal
    check_install_sentinel "cursor" "validate_mounted_env_files" "plugin_marketplace"
    local event_dir
    event_dir="$(get_telemetry_dir)"
    [[ -f "${event_dir}/.installed-cursor-validate_mounted_env_files-plugin_marketplace" ]]
    [[ -f "${event_dir}/events.jsonl" ]]
}

@test "check_install_sentinel: no-op on second call" {
    create_consent_signal
    check_install_sentinel "cursor" "validate_mounted_env_files" "plugin_marketplace"
    local event_file
    event_file="$(get_telemetry_dir)/events.jsonl"
    local count_before
    count_before=$(wc -l < "$event_file" | tr -d ' ')
    check_install_sentinel "cursor" "validate_mounted_env_files" "plugin_marketplace"
    local count_after
    count_after=$(wc -l < "$event_file" | tr -d ' ')
    [[ "$count_before" -eq "$count_after" ]]
}

@test "check_install_sentinel: no-op when consent absent" {
    check_install_sentinel "cursor" "validate_mounted_env_files" "plugin_marketplace"
    local event_dir
    event_dir="$(get_telemetry_dir)"
    [[ ! -f "${event_dir}/.installed-cursor-validate_mounted_env_files-plugin_marketplace" ]]
}

# ========== detect_install_method ==========

@test "detect_install_method: returns plugin_marketplace when CURSOR_PLUGIN_ROOT set" {
    export CURSOR_PLUGIN_ROOT="/path/to/plugin"
    run detect_install_method "/some/dir"
    [[ "$output" == "plugin_marketplace" ]]
    unset CURSOR_PLUGIN_ROOT
}

@test "detect_install_method: returns plugin_marketplace when CLAUDE_PLUGIN_ROOT set" {
    export CLAUDE_PLUGIN_ROOT="/path/to/plugin"
    run detect_install_method "/some/dir"
    [[ "$output" == "plugin_marketplace" ]]
    unset CLAUDE_PLUGIN_ROOT
}

@test "detect_install_method: returns install_script when path contains bundle marker" {
    run detect_install_method "/project/.cursor/cursor-1password-hooks-bundle/bin"
    [[ "$output" == "install_script" ]]
}

@test "detect_install_method: returns unknown when no signal matches" {
    run detect_install_method "/some/random/dir"
    [[ "$output" == "unknown" ]]
}
