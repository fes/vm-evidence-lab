#!/usr/bin/env sh
set -eu

script_dir=${VM_EVIDENCE_CONTROLLER_ROOT:-$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)}
repository_root=$(unset CDPATH; cd -- "$script_dir/.." && pwd)
# shellcheck source=host/lib.sh
. "$script_dir/lib.sh"

config_path=${VM_EVIDENCE_CONFIG:-"$HOME/.config/vm-evidence-lab/config.json"}

watchdog_seconds() {
    phase=$1
    fallback=$2
    jq -er --arg field "${phase}_seconds" --argjson fallback "$fallback" \
        '.watchdog[$field] // $fallback' "$config_path"
}

poll_seconds() {
    jq -er '.watchdog.poll_seconds // 2' "$config_path"
}

load_config() {
    [ -f "$config_path" ] || vm_evidence_die "configuration not found: $config_path"
    for command in git jq scp shasum ssh uuidgen; do
        vm_evidence_require_command "$command"
    done
    jq -e '
        (.provider | type == "string" and test("^[a-z][a-z0-9-]{0,63}$")) and
        (.artifact_root | type == "string" and length > 0) and
        (.adapters | type == "object") and
        (.vms.windows and .vms.linux and .vms.macos)
    ' "$config_path" >/dev/null || vm_evidence_die "invalid configuration: $config_path"
    provider=$(jq -er '.provider' "$config_path")
    provider_path="$repository_root/providers/$provider.sh"
    [ -f "$provider_path" ] || vm_evidence_die "provider is unavailable: $provider"
    # shellcheck disable=SC1090
    . "$provider_path"
    provider_require
}

vm_field() {
    jq -er --arg platform "$1" --arg field "$2" \
        '.vms[$platform][$field]' "$config_path"
}

vm_name() {
    vm_field "$1" name
}

guest_target() {
    printf '%s@%s' "$(vm_field "$1" user)" "$(vm_field "$1" host)"
}

guest_ssh() {
    platform=$1
    shift
    key=$(jq -er '.ssh_private_key // empty' "$config_path")
    port=$(vm_field "$platform" port)
    # shellcheck disable=SC2029
    if [ -n "$key" ]; then
        ssh -i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 \
            "$(guest_target "$platform")" "$@"
    else
        ssh -p "$port" -o BatchMode=yes -o ConnectTimeout=10 \
            "$(guest_target "$platform")" "$@"
    fi
}

guest_scp() {
    platform=$1
    local_path=$2
    remote_path=$3
    key=$(jq -er '.ssh_private_key // empty' "$config_path")
    port=$(vm_field "$platform" port)
    if [ -n "$key" ]; then
        scp -i "$key" -P "$port" -o BatchMode=yes -o ConnectTimeout=10 \
            "$local_path" "$(guest_target "$platform"):$remote_path"
    else
        scp -P "$port" -o BatchMode=yes -o ConnectTimeout=10 \
            "$local_path" "$(guest_target "$platform"):$remote_path"
    fi
}

guest_windows_powershell() {
    guest_ssh "$1" "powershell.exe -NoProfile -NonInteractive -Command \"$2\""
}

wait_for_ssh() {
    platform=$1
    timeout=$(watchdog_seconds ssh 120)
    poll=$(poll_seconds)
    ssh_deadline=$(($(date +%s) + timeout))
    if [ -n "${run_deadline:-}" ] && [ "$run_deadline" -lt "$ssh_deadline" ]; then
        ssh_deadline=$run_deadline
    fi
    while [ "$(date +%s)" -lt "$ssh_deadline" ]; do
        if [ "$platform" = windows ]; then
            probe='powershell.exe -NoProfile -NonInteractive -Command "exit 0"'
        else
            probe=true
        fi
        if guest_ssh "$platform" "$probe" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$poll"
    done
    vm_evidence_die "$platform did not become reachable within ${timeout} seconds"
}

status_vm() {
    platform=$1
    provider_vm_exists "$(vm_name "$platform")" ||
        vm_evidence_die "VM not found: $(vm_name "$platform")"
    provider_metadata "$(vm_name "$platform")"
}

reset_vm() {
    platform=$1
    provider_vm_exists "$(vm_name "$platform")" ||
        vm_evidence_die "VM not found: $(vm_name "$platform")"
    provider_reset "$(vm_name "$platform")" "$(vm_field "$platform" snapshot_id)"
}

locked_reset_vm() (
    platform=$1
    artifact_root=$(jq -er '.artifact_root' "$config_path")
    reset_lock_path="$artifact_root/.locks/lab"
    vm_evidence_acquire_lock "$reset_lock_path"
    trap 'vm_evidence_release_lock "$reset_lock_path"' 0
    trap 'exit 130' 1 2 15
    reset_vm "$platform"
)

capture_vm() {
    platform=$1
    output=$2
    mkdir -p "$(dirname -- "$output")"
    provider_capture "$(vm_name "$platform")" "$output"
}

controller_sha() {
    git -C "$repository_root" rev-parse HEAD
}

relay_sha() {
    git -C "$repository_root" rev-parse HEAD:relay
}

read_relay_version() {
    platform=$1
    spool=$(vm_field "$platform" relay_spool)
    case "$platform" in
        windows)
            guest_windows_powershell "$platform" \
                "if (Test-Path -LiteralPath '$spool\\relay-version.txt') { Get-Content -Raw -LiteralPath '$spool\\relay-version.txt' }"
            ;;
        *)
            guest_ssh "$platform" \
                "test -f '$spool/relay-version.txt' && cat '$spool/relay-version.txt'"
            ;;
    esac
}

sync_relay() {
    platform=$1
    version=$2
    if installed=$(read_relay_version "$platform" 2>/dev/null); then
        [ "$(printf '%s' "$installed" | tr -d '\r\n')" = "$version" ] && return 0
    fi
    spool=$(vm_field "$platform" relay_spool)
    case "$platform" in
        windows)
            relay_script=$(vm_field "$platform" relay_script)
            stage="$spool\\jobs\\.relay-$version.ps1"
            guest_scp "$platform" "$repository_root/relay/windows.ps1" "$stage"
            guest_windows_powershell "$platform" \
                "Copy-Item -LiteralPath '$stage' -Destination '$relay_script' -Force; Set-Content -LiteralPath '$spool\\relay-version.txt' -Value '$version' -NoNewline; Remove-Item -LiteralPath '$stage' -Force"
            ;;
        *)
            install_root=$(vm_field "$platform" relay_install_root)
            guest_ssh "$platform" "mkdir -p '$install_root' '$spool/jobs'"
            guest_scp "$platform" "$repository_root/relay/common.sh" "$install_root/common.sh"
            guest_scp "$platform" "$repository_root/relay/unix.sh" "$install_root/unix.sh"
            guest_ssh "$platform" \
                "chmod 755 '$install_root/common.sh' '$install_root/unix.sh'; printf '%s' '$version' > '$spool/relay-version.txt'"
            ;;
    esac
}

read_adapter_version() {
    platform=$1
    adapter_id=$2
    adapter_root=$(vm_field "$platform" adapter_root)
    case "$platform" in
        windows)
            guest_windows_powershell "$platform" \
                "if (Test-Path -LiteralPath '$adapter_root\\$adapter_id\\adapter-version.txt') { Get-Content -Raw -LiteralPath '$adapter_root\\$adapter_id\\adapter-version.txt' }"
            ;;
        *)
            guest_ssh "$platform" \
                "test -f '$adapter_root/$adapter_id/adapter-version.txt' && cat '$adapter_root/$adapter_id/adapter-version.txt'"
            ;;
    esac
}

sync_adapter() {
    platform=$1
    adapter_id=$2
    adapter_sha=$(jq -er --arg adapter "$adapter_id" \
        '.adapters[$adapter].adapter_sha' "$config_path")
    if installed=$(read_adapter_version "$platform" "$adapter_id" 2>/dev/null); then
        [ "$(printf '%s' "$installed" | tr -d '\r\n')" = "$adapter_sha" ] && return 0
    fi

    adapter_repository=$(jq -er --arg adapter "$adapter_id" \
        '.adapters[$adapter].adapter_repository' "$config_path")
    adapter_path=$(jq -er --arg adapter "$adapter_id" \
        '.adapters[$adapter].adapter_path' "$config_path")
    vm_evidence_full_sha "$adapter_repository" "$adapter_sha" >/dev/null
    adapter_stage=$(mktemp -d "${TMPDIR:-/tmp}/vm-evidence-adapter.XXXXXX")
    case "$platform" in
        windows) adapter_entry=windows.ps1 ;;
        *) adapter_entry=$platform.sh ;;
    esac
    for file in policy.json "$adapter_entry"; do
        git -C "$adapter_repository" show "$adapter_sha:$adapter_path/$file" \
            >"$adapter_stage/$file" ||
            vm_evidence_die "adapter file is unavailable at $adapter_sha: $adapter_path/$file"
    done
    printf '%s' "$adapter_sha" >"$adapter_stage/adapter-version.txt"

    adapter_root=$(vm_field "$platform" adapter_root)
    case "$platform" in
        windows)
            guest_windows_powershell "$platform" \
                "New-Item -ItemType Directory -Force -Path '$adapter_root\\$adapter_id' | Out-Null"
            for file in policy.json windows.ps1 adapter-version.txt; do
                guest_scp "$platform" "$adapter_stage/$file" \
                    "$adapter_root\\$adapter_id\\.$file.partial"
                guest_windows_powershell "$platform" \
                    "Move-Item -LiteralPath '$adapter_root\\$adapter_id\\.$file.partial' -Destination '$adapter_root\\$adapter_id\\$file' -Force"
            done
            ;;
        *)
            guest_ssh "$platform" "mkdir -p '$adapter_root/$adapter_id'"
            for file in policy.json "$adapter_entry" adapter-version.txt; do
                guest_scp "$platform" "$adapter_stage/$file" \
                    "$adapter_root/$adapter_id/.$file.partial"
                guest_ssh "$platform" \
                    "mv '$adapter_root/$adapter_id/.$file.partial' '$adapter_root/$adapter_id/$file'"
            done
            guest_ssh "$platform" "chmod 755 '$adapter_root/$adapter_id/$platform.sh'"
            ;;
    esac
    rm -rf "$adapter_stage"
}

prepare_host_input() {
    platform=$1
    request=$2
    output=$3
    host_input_engaged=0
    host_input_completed=0
    host_input_descriptor_sha256=
    [ "$platform" = windows ] || return 0

    adapter_id=$(jq -er '.adapter_id' "$request")
    mode=$(jq -er '.mode' "$request")
    adapter_repository=$(jq -er --arg adapter "$adapter_id" \
        '.adapters[$adapter].adapter_repository' "$config_path")
    adapter_path=$(jq -er --arg adapter "$adapter_id" \
        '.adapters[$adapter].adapter_path' "$config_path")
    adapter_sha=$(jq -er --arg adapter "$adapter_id" \
        '.adapters[$adapter].adapter_sha' "$config_path")
    vm_evidence_full_sha "$adapter_repository" "$adapter_sha" >/dev/null
    if ! git -C "$adapter_repository" cat-file -e \
        "$adapter_sha:$adapter_path/host-input.json" 2>/dev/null; then
        return 0
    fi
    git -C "$adapter_repository" show \
        "$adapter_sha:$adapter_path/host-input.json" >"$output"
    "$script_dir/validate-host-input.sh" "$output" ||
        vm_evidence_die "invalid pinned host-input descriptor: $adapter_id/$mode"
    jq -e --arg mode "$mode" '(.modes | index($mode)) != null' "$output" >/dev/null ||
        return 0
    host_input_engaged=1
    host_input_descriptor_sha256=$(shasum -a 256 "$output" | awk '{print $1}')
}

quarantine_stale_jobs() {
    platform=$1
    spool=$(vm_field "$platform" relay_spool)
    case "$platform" in
        windows)
            guest_windows_powershell "$platform" \
                "\$jobs = '$spool\\jobs'; Get-ChildItem -LiteralPath \$jobs -Filter '*.json' -File | Where-Object { \$_.Name -notlike 'processed-*' -and \$_.Name -notlike 'rejected-*' -and \$_.Name -notlike 'infrastructure-failed-*' } | ForEach-Object { Move-Item -LiteralPath \$_.FullName -Destination (Join-Path \$jobs ('infrastructure-failed-' + \$_.Name)) }"
            ;;
        *)
            guest_ssh "$platform" \
                "find '$spool/jobs' -maxdepth 1 -type f -name '*.json' ! -name 'processed-*' ! -name 'rejected-*' ! -name 'infrastructure-failed-*' -exec sh -c 'for path; do directory=\$(dirname \"\$path\"); mv \"\$path\" \"\$directory/infrastructure-failed-\$(basename \"\$path\")\"; done' sh {} +"
            ;;
    esac
}

validate_request() {
    request=$1
    jq -e '
        (keys | sort) ==
          (["adapter_id", "adapter_schema_version", "mode", "payload",
            "schema_version", "sources"] | sort) and
        .schema_version == 1 and
        (.adapter_id | type == "string" and test("^[a-z][a-z0-9-]{0,63}$")) and
        (.adapter_schema_version | type == "number" and . >= 1 and floor == .) and
        (.mode | type == "string" and test("^[a-z][a-z0-9-]{0,63}$")) and
        (.sources | type == "array" and length >= 1 and length <= 8) and
        ([.sources[].id] | length == (unique | length)) and
        (all(.sources[];
          (keys | sort) == (["id", "sha"] | sort) and
          (.id | type == "string" and test("^[a-z][a-z0-9-]{0,63}$")) and
          (.sha | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$"))
        )) and
        (.payload | type == "object")
    ' "$request" >/dev/null || vm_evidence_die "invalid host request: $request"

    adapter_id=$(jq -er '.adapter_id' "$request")
    adapter_schema_version=$(jq -er '.adapter_schema_version' "$request")
    mode=$(jq -er '.mode' "$request")
    jq -e --arg adapter "$adapter_id" --arg mode "$mode" \
        --argjson schema "$adapter_schema_version" '
        .adapters[$adapter].schema_version == $schema and
        (.adapters[$adapter].adapter_sha |
          type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
        (.adapters[$adapter].safe_modes | index($mode)) != null
    ' "$config_path" >/dev/null ||
        vm_evidence_die "adapter mode is not installed and watchdog-safe: $adapter_id/$mode"
}

publish_job() {
    platform=$1
    request=$2
    run_id=$3
    temporary_root=$4
    spool=$(vm_field "$platform" relay_spool)
    adapter_id=$(jq -er '.adapter_id' "$request")
    sources='[]'
    mkdir -p "$temporary_root/bundle-repositories"
    jq -c '.sources[]' "$request" |
    while IFS= read -r source; do
        source_id=$(printf '%s' "$source" | jq -er '.id')
        local_repository=$(jq -er --arg adapter "$adapter_id" --arg source "$source_id" \
            '.adapters[$adapter].sources[$source].repository' "$config_path") ||
            vm_evidence_die "source ID is not trusted for adapter: $adapter_id/$source_id"
        requested_sha=$(printf '%s' "$source" | jq -er '.sha')
        bundle_name=$(vm_evidence_bundle_name "$run_id" "$source_id")
        vm_evidence_create_bundle "$local_repository" "$requested_sha" \
            "$temporary_root/$bundle_name" \
            "$temporary_root/bundle-repositories/$source_id"
        printf '%s\t%s\t%s\n' "$source_id" "$requested_sha" "$bundle_name"
    done >"$temporary_root/sources.rows"

    while IFS="$(printf '\t')" read -r source_id requested_sha bundle_name; do
        sources=$(printf '%s' "$sources" |
            jq --arg id "$source_id" --arg sha "$requested_sha" --arg bundle "$bundle_name" \
                '. + [{id: $id, sha: $sha, bundle: $bundle}]')
    done <"$temporary_root/sources.rows"

    jq -n \
        --argjson schema_version 1 \
        --arg run_id "$run_id" \
        --arg adapter_id "$adapter_id" \
        --arg adapter_sha "$(jq -er --arg adapter "$adapter_id" \
            '.adapters[$adapter].adapter_sha' "$config_path")" \
        --argjson adapter_schema_version "$(jq -er '.adapter_schema_version' "$request")" \
        --arg mode "$(jq -er '.mode' "$request")" \
        --arg platform "$platform" \
        --argjson sources "$sources" \
        --argjson payload "$(jq -c '.payload' "$request")" \
        '{
          schema_version: $schema_version,
          run_id: $run_id,
          adapter_id: $adapter_id,
          adapter_sha: $adapter_sha,
          adapter_schema_version: $adapter_schema_version,
          mode: $mode,
          platform: $platform,
          sources: $sources,
          payload: $payload
        }' >"$temporary_root/job.json"

    for bundle_path in "$temporary_root"/*.bundle; do
        bundle_name=$(basename "$bundle_path")
        case "$platform" in
            windows)
                guest_scp "$platform" "$bundle_path" "$spool\\bundles\\.$bundle_name.partial"
                guest_windows_powershell "$platform" \
                    "Move-Item -LiteralPath '$spool\\bundles\\.$bundle_name.partial' -Destination '$spool\\bundles\\$bundle_name'"
                ;;
            *)
                guest_scp "$platform" "$bundle_path" "$spool/bundles/.$bundle_name.partial"
                guest_ssh "$platform" \
                    "mv '$spool/bundles/.$bundle_name.partial' '$spool/bundles/$bundle_name'"
                ;;
        esac
    done

    case "$platform" in
        windows)
            guest_scp "$platform" "$temporary_root/job.json" "$spool\\jobs\\.$run_id.partial"
            guest_windows_powershell "$platform" \
                "Move-Item -LiteralPath '$spool\\jobs\\.$run_id.partial' -Destination '$spool\\jobs\\$run_id.json'"
            (
                set +e
                provider_exec_current_user "$(vm_name "$platform")" \
                    powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
                    "$(vm_field "$platform" relay_script)" \
                    -Spool "$spool" \
                    -RepositoryRoot "$(vm_field "$platform" relay_repository_root)" \
                    -AdapterRoot "$(vm_field "$platform" adapter_root)" \
                    -Platform windows \
                    >"$temporary_root/relay-activation.log" 2>&1
                printf '%s\n' "$?" >"$temporary_root/relay-activation.status"
            ) &
            relay_activation_pid=$!
            ;;
        *)
            guest_scp "$platform" "$temporary_root/job.json" "$spool/jobs/.$run_id.partial"
            guest_ssh "$platform" "mv '$spool/jobs/.$run_id.partial' '$spool/jobs/$run_id.json'"
            ;;
    esac
}

read_host_input_stage() {
    hi_read_platform=$1
    hi_read_run_id=$2
    hi_read_stage=$3
    hi_read_spool=$(vm_field "$hi_read_platform" relay_spool)
    guest_windows_powershell "$hi_read_platform" \
        "if (Test-Path -LiteralPath '$hi_read_spool\\artifacts\\$hi_read_run_id\\host-input\\$hi_read_stage.json') { Get-Content -Raw -LiteralPath '$hi_read_spool\\artifacts\\$hi_read_run_id\\host-input\\$hi_read_stage.json'; exit 0 }; exit 3"
}

wait_for_host_input_stage() {
    hi_wait_platform=$1
    hi_wait_run_id=$2
    hi_wait_stage=$3
    hi_wait_timeout=$4
    hi_wait_poll=$(poll_seconds)
    hi_wait_deadline=$(($(date +%s) + hi_wait_timeout))
    if [ -n "${run_deadline:-}" ] && [ "$run_deadline" -lt "$hi_wait_deadline" ]; then
        hi_wait_deadline=$run_deadline
    fi
    while [ "$(date +%s)" -lt "$hi_wait_deadline" ]; do
        if hi_wait_result=$(read_result "$hi_wait_platform" "$hi_wait_run_id" 2>/dev/null); then
            hi_wait_status=$(printf '%s' "$hi_wait_result" | jq -er '.status')
            if [ "$hi_wait_status" = fail ]; then
                printf '%s\n' "$hi_wait_result" >"$temporary_root/early-guest-result.json"
                return 20
            elif [ "$hi_wait_status" = pass ]; then
                vm_evidence_die "Windows relay completed before host-input stage: $hi_wait_stage"
            fi
        else
            hi_wait_result_status=$?
            [ "$hi_wait_result_status" -eq 3 ] ||
                vm_evidence_die "Windows control plane failed reading relay result"
        fi
        if [ -f "$temporary_root/relay-activation.status" ]; then
            hi_wait_relay_status=$(cat "$temporary_root/relay-activation.status")
            if [ "$hi_wait_relay_status" -ne 0 ]; then
                cat "$temporary_root/relay-activation.log" >&2
                vm_evidence_die "Windows graphical-session relay activation failed"
            fi
            vm_evidence_die \
                "Windows graphical-session relay exited before host-input stage: $hi_wait_stage"
        fi
        if hi_wait_state=$(read_host_input_stage \
            "$hi_wait_platform" "$hi_wait_run_id" "$hi_wait_stage" 2>/dev/null); then
            printf '%s' "$hi_wait_state" |
                jq -e --arg run_id "$hi_wait_run_id" --arg stage "$hi_wait_stage" '
                (keys | sort) == (["run_id", "schema_version", "stage"] | sort) and
                .schema_version == 1 and .run_id == $run_id and .stage == $stage
            ' >/dev/null ||
                vm_evidence_die "invalid host-input state for stage: $hi_wait_stage"
            return 0
        else
            hi_wait_state_status=$?
            [ "$hi_wait_state_status" -eq 3 ] ||
                vm_evidence_die "Windows control plane failed reading host-input state"
        fi
        sleep "$hi_wait_poll"
    done
    vm_evidence_die "Windows host-input stage timed out: $hi_wait_stage"
}

drive_host_input() {
    hi_drive_platform=$1
    hi_drive_run_id=$2
    hi_drive_descriptor=$3
    hi_drive_initial_timeout=$(jq -er '.initial_timeout_seconds' "$hi_drive_descriptor")
    hi_drive_stage_timeout=$(jq -er '.stage_timeout_seconds' "$hi_drive_descriptor")
    hi_drive_stage_index=0
    hi_drive_stage_count=$(jq -er '.stages | length' "$hi_drive_descriptor")
    while [ "$hi_drive_stage_index" -lt "$hi_drive_stage_count" ]; do
        hi_drive_stage_json=$(jq -c --argjson index "$hi_drive_stage_index" \
            '.stages[$index]' "$hi_drive_descriptor")
        hi_drive_stage_name=$(printf '%s' "$hi_drive_stage_json" | jq -er '.wait_for')
        if [ "$hi_drive_stage_index" -eq 0 ]; then
            hi_drive_timeout=$hi_drive_initial_timeout
        else
            hi_drive_timeout=$hi_drive_stage_timeout
        fi
        if wait_for_host_input_stage \
            "$hi_drive_platform" "$hi_drive_run_id" \
            "$hi_drive_stage_name" "$hi_drive_timeout"; then
            :
        else
            return $?
        fi
        hi_drive_settle_seconds=$(printf '%s' "$hi_drive_stage_json" |
            jq -er '.settle_seconds')
        if [ "$hi_drive_settle_seconds" -gt 0 ]; then
            sleep "$hi_drive_settle_seconds"
        fi
        hi_drive_event_index=0
        hi_drive_event_count=$(printf '%s' "$hi_drive_stage_json" |
            jq -er '.events | length')
        while [ "$hi_drive_event_index" -lt "$hi_drive_event_count" ]; do
            hi_drive_event=$(printf '%s' "$hi_drive_stage_json" |
                jq -c --argjson index "$hi_drive_event_index" '.events[$index]')
            hi_drive_event_type=$(printf '%s' "$hi_drive_event" | jq -er '.type')
            hi_drive_code=$(printf '%s' "$hi_drive_event" | jq -er '.code')
            if ! provider_send_input_event \
                "$(vm_name "$hi_drive_platform")" \
                "$hi_drive_event_type" "$hi_drive_code"; then
                return 21
            fi
            hi_drive_event_index=$((hi_drive_event_index + 1))
        done
        hi_drive_stage_index=$((hi_drive_stage_index + 1))
    done
    host_input_completed=1
}

finish_relay_activation() {
    if [ -n "${relay_activation_pid:-}" ]; then
        wait "$relay_activation_pid"
        relay_status=$(cat "$temporary_root/relay-activation.status")
        if [ "$relay_status" -ne 0 ]; then
            cat "$temporary_root/relay-activation.log" >&2
            vm_evidence_die "Windows graphical-session relay activation failed"
        fi
        relay_activation_pid=
    fi
}

read_result() {
    platform=$1
    run_id=$2
    spool=$(vm_field "$platform" relay_spool)
    case "$platform" in
        windows)
            guest_windows_powershell "$platform" \
                "if (Test-Path -LiteralPath '$spool\\results\\$run_id.json') { Get-Content -Raw -LiteralPath '$spool\\results\\$run_id.json'; exit 0 }; exit 3"
            ;;
        *)
            guest_ssh "$platform" \
                "if test -f '$spool/results/$run_id.json'; then cat '$spool/results/$run_id.json'; else exit 3; fi"
            ;;
    esac
}

wait_for_result() {
    platform=$1
    run_id=$2
    overall=$(watchdog_seconds overall 2400)
    poll=$(poll_seconds)
    phase=
    result_deadline=${run_deadline:-$(($(date +%s) + overall))}
    phase_deadline=$result_deadline
    while [ "$(date +%s)" -lt "$result_deadline" ]; do
        if result=$(read_result "$platform" "$run_id" 2>/dev/null); then
            status=$(printf '%s' "$result" | jq -er '.status')
            current_phase=$(printf '%s' "$result" | jq -er '.phase')
            if [ "$status" = running ]; then
                if [ "$current_phase" != "$phase" ]; then
                    phase=$current_phase
                    case "$phase" in
                        queued|preflight) phase_timeout=$(watchdog_seconds readiness 180) ;;
                        checkout) phase_timeout=$(watchdog_seconds checkout 300) ;;
                        adapter) phase_timeout=$(watchdog_seconds adapter 1800) ;;
                        *) vm_evidence_die "relay reported unsupported phase: $phase" ;;
                    esac
                    phase_deadline=$(($(date +%s) + phase_timeout))
                    [ "$phase_deadline" -lt "$result_deadline" ] ||
                        phase_deadline=$result_deadline
                fi
                [ "$(date +%s)" -lt "$phase_deadline" ] ||
                    vm_evidence_die "$platform relay exceeded ${phase} deadline"
            elif [ "$status" = pass ] || [ "$status" = fail ]; then
                printf '%s\n' "$result"
                return 0
            else
                vm_evidence_die "relay returned invalid status for $run_id"
            fi
        else
            result_status=$?
            [ "$result_status" -eq 3 ] ||
                vm_evidence_die "$platform control plane failed reading result"
        fi
        sleep "$poll"
    done
    vm_evidence_die "$platform relay did not finish within ${overall} seconds"
}

cleanup_run() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    set +e
    if [ -n "${relay_activation_pid:-}" ]; then
        if [ "${run_platform:-}" = windows ] && [ -n "${run_id:-}" ]; then
            spool=$(vm_field windows relay_spool)
            guest_windows_powershell windows \
                "\$path = '$spool\\artifacts\\$run_id\\relay.pid'; if (Test-Path -LiteralPath \$path) { \$relayPid = [int](Get-Content -Raw -LiteralPath \$path); taskkill.exe /PID \$relayPid /T /F 2>\$null | Out-Null }" \
                >/dev/null 2>&1
        fi
        kill "$relay_activation_pid" >/dev/null 2>&1
        wait "$relay_activation_pid" >/dev/null 2>&1
    fi
    if [ "${run_started:-0}" -eq 1 ]; then
        capture_vm "$run_platform" "$run_root/desktop-final.png"
        provider_metadata "$(vm_name "$run_platform")" >"$run_root/provider-metadata.json"
        provider_stop "$(vm_name "$run_platform")"
    fi
    [ "$exit_status" -eq 0 ] ||
        printf 'controller exited with status %s at %s\n' "$exit_status" \
            "$(date -u +%FT%TZ)" >"$run_root/controller-failure.txt"
    rm -rf "$temporary_root"
    vm_evidence_release_lock "$lock_path"
    exit "$exit_status"
}

run_platform() {
    platform=$1
    request=$2
    vm_evidence_validate_platform "$platform"
    validate_request "$request"
    adapter_id=$(jq -er '.adapter_id' "$request")
    mode=$(jq -er '.mode' "$request")
    run_id="$(date -u +%Y%m%dT%H%M%SZ)-$platform-$adapter_id-$(uuidgen | tr '[:upper:]' '[:lower:]')"
    artifact_root=$(jq -er '.artifact_root' "$config_path")
    run_root="$artifact_root/$run_id"
    lock_path="$artifact_root/.locks/lab"
    temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/vm-evidence.XXXXXX")
    relay_activation_pid=
    vm_evidence_acquire_lock "$lock_path"
    [ ! -e "$run_root" ] || vm_evidence_die "run directory exists: $run_root"
    mkdir -p "$run_root"
    run_platform=$platform
    run_started=0
    run_deadline=$(($(date +%s) + $(watchdog_seconds overall 2400)))
    trap cleanup_run EXIT HUP INT TERM

    reset_vm "$platform"
    provider_wait_for_restore "$(vm_name "$platform")" "$(watchdog_seconds restore 120)"
    provider_start "$(vm_name "$platform")"
    run_started=1
    wait_for_ssh "$platform"
    requested_relay_sha=$(relay_sha)
    sync_relay "$platform" "$requested_relay_sha"
    sync_adapter "$platform" "$adapter_id"
    prepare_host_input "$platform" "$request" "$temporary_root/host-input.json"
    quarantine_stale_jobs "$platform"
    capture_vm "$platform" "$run_root/desktop-ready.png"
    publish_job "$platform" "$request" "$run_id" "$temporary_root"
    if [ "$host_input_engaged" -eq 1 ]; then
        if drive_host_input "$platform" "$run_id" "$temporary_root/host-input.json"; then
            :
        else
            host_input_status=$?
            [ "$host_input_status" -eq 20 ] ||
                vm_evidence_die "Windows host-input driver failed"
        fi
    fi
    if [ -f "$temporary_root/early-guest-result.json" ]; then
        result=$(cat "$temporary_root/early-guest-result.json")
    else
        result=$(wait_for_result "$platform" "$run_id")
    fi
    finish_relay_activation
    printf '%s\n' "$result" >"$run_root/guest-result.json"
    provider_metadata "$(vm_name "$platform")" >"$run_root/provider-metadata.json"
    jq -n \
        --argjson schema_version 1 \
        --arg run_id "$run_id" \
        --arg platform "$platform" \
        --arg controller_sha "$(controller_sha)" \
        --arg relay_sha "$requested_relay_sha" \
        --arg adapter_id "$adapter_id" \
        --arg adapter_sha "$(jq -er --arg adapter "$adapter_id" \
            '.adapters[$adapter].adapter_sha' "$config_path")" \
        --argjson adapter_schema_version "$(jq -er '.adapter_schema_version' "$request")" \
        --arg mode "$mode" \
        --argjson host_input_engaged "$host_input_engaged" \
        --argjson host_input_completed "$host_input_completed" \
        --arg host_input_descriptor_sha256 "$host_input_descriptor_sha256" \
        --arg created_at "$(date -u +%FT%TZ)" \
        --argjson requested_sources "$(jq -c '[.sources[] | {id, sha}]' "$request")" \
        --slurpfile provider "$run_root/provider-metadata.json" \
        --slurpfile guest "$run_root/guest-result.json" \
        '{
          schema_version: $schema_version,
          run_id: $run_id,
          platform: $platform,
          provider: $provider[0],
          controller_sha: $controller_sha,
          relay_sha: $relay_sha,
          adapter_id: $adapter_id,
          adapter_sha: $adapter_sha,
          adapter_schema_version: $adapter_schema_version,
          mode: $mode,
          requested_sources: $requested_sources,
          host_input: (
            if $host_input_engaged == 1 then {
              engaged: true,
              descriptor_sha256: $host_input_descriptor_sha256,
              completed: ($host_input_completed == 1)
            } else {
              engaged: false
            } end
          ),
          guest_result: $guest[0],
          created_at: $created_at
        }' >"$run_root/manifest.json"
    jq -e '.guest_result.status == "pass"' "$run_root/manifest.json" >/dev/null
}

usage() {
    cat >&2 <<'EOF'
Usage:
  controller.sh status <windows|linux|macos>
  controller.sh reset <windows|linux|macos>
  controller.sh capture <windows|linux|macos> <png-path>
  controller.sh run <windows|linux|macos> <host-request.json>
  controller.sh all <host-request.json>
EOF
    exit 2
}

if [ "${VM_EVIDENCE_CONTROLLER_LIBRARY_ONLY:-0}" -eq 1 ]; then
    return 0 2>/dev/null || exit 0
fi

[ "$#" -ge 1 ] || usage
load_config

case "$1" in
    status)
        [ "$#" -eq 2 ] || usage
        vm_evidence_validate_platform "$2"
        status_vm "$2"
        ;;
    reset)
        [ "$#" -eq 2 ] || usage
        vm_evidence_validate_platform "$2"
        locked_reset_vm "$2"
        ;;
    capture)
        [ "$#" -eq 3 ] || usage
        vm_evidence_validate_platform "$2"
        capture_vm "$2" "$3"
        ;;
    run)
        [ "$#" -eq 3 ] || usage
        run_platform "$2" "$3"
        ;;
    all)
        [ "$#" -eq 2 ] || usage
        failed=0
        for platform in windows linux macos; do
            (run_platform "$platform" "$2") || failed=1
        done
        exit "$failed"
        ;;
    *)
        usage
        ;;
esac
