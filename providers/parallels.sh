#!/usr/bin/env sh

provider_require() {
    command -v prlctl >/dev/null 2>&1 ||
        vm_evidence_die 'prlctl is required for the Parallels provider'
}

provider_vm_exists() {
    prlctl list --all --json |
        jq -e --arg name "$1" '.[] | select(.name == $name)' >/dev/null
}

provider_vm_running() {
    [ "$(prlctl list "$1" --json | jq -er '.[0].status')" = running ]
}

provider_reset() {
    prlctl snapshot-switch "$1" --id "$2"
}

provider_wait_for_restore() {
    vm_name=$1
    timeout_seconds=$2
    elapsed=0
    while [ "$elapsed" -lt "$timeout_seconds" ]; do
        state=$(prlctl list "$vm_name" --json | jq -er '.[0].status')
        [ "$state" != restoring ] && return 0
        sleep 2
        elapsed=$((elapsed + 2))
    done
    vm_evidence_die "$vm_name remained in restoring state for ${timeout_seconds} seconds"
}

provider_start() {
    state=$(prlctl list "$1" --json | jq -er '.[0].status')
    [ "$state" = running ] || prlctl start "$1"
}

provider_stop() {
    prlctl stop "$1"
}

provider_capture() {
    vm_name=$1
    output=$2
    partial="${output}.partial"
    rm -f "$partial"
    attempt=1
    while [ "$attempt" -le 5 ]; do
        if prlctl capture "$vm_name" --file "$partial"; then
            wait_attempt=1
            while [ "$wait_attempt" -le 5 ]; do
                if [ -s "$partial" ]; then
                    mv "$partial" "$output"
                    return 0
                fi
                sleep 1
                wait_attempt=$((wait_attempt + 1))
            done
        fi
        rm -f "$partial"
        printf 'vm-evidence: capture attempt %s/5 has not produced output for %s\n' \
            "$attempt" "$vm_name" >&2
        attempt=$((attempt + 1))
        sleep 1
    done
    vm_evidence_die "could not capture $vm_name after 5 attempts"
}

provider_exec_current_user() {
    vm_name=$1
    shift
    prlctl exec "$vm_name" --current-user "$@"
}

provider_metadata() {
    version=$(prlctl --version 2>/dev/null || printf unknown)
    vm=$(prlctl list "$1" --json)
    jq -n --arg provider parallels --arg version "$version" --argjson vm "$vm" \
        '{provider: $provider, version: $version, vm: $vm}'
}

provider_interaction_capabilities() {
    version=$(prlctl --version 2>/dev/null || printf unknown)
    jq -n --arg version "$version" '{
      schema_version: 1,
      provider: "parallels",
      provider_version: $version,
      lifecycle: true,
      capture_guest_display: true,
      keyboard_virtual_keys: true,
      pointer: false,
      wheel: false,
      gestures: false,
      window_observation: false,
      accessibility: false,
      clipboard_io: false,
      video: false,
      notes: [
        "Pointer, wheel, focus, accessibility and video require a guest-side agent or the macOS host observer.",
        "Clipboard policy is not clipboard content I/O and remains disabled for evidence runs."
      ]
    }'
}
