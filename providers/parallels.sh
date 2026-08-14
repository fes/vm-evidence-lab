#!/usr/bin/env sh

provider_require() {
    command -v prlctl >/dev/null 2>&1 ||
        vm_evidence_die 'prlctl is required for the Parallels provider'
}

provider_vm_exists() {
    prlctl list --all --json |
        jq -e --arg name "$1" '.[] | select(.name == $name)' >/dev/null
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
    prlctl capture "$1" --file "$2"
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
