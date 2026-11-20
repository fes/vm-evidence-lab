#!/usr/bin/env sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(unset CDPATH; cd -- "$script_dir/.." && pwd)
# shellcheck source=host/lib.sh
. "$script_dir/lib.sh"

config_path=${VM_EVIDENCE_CONFIG:-"$HOME/.config/vm-evidence-lab/config.json"}
python_command=${PYTHON:-python3}

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
    for command in git jq scp ssh uuidgen "$python_command"; do
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

guest_scp_from() {
    platform=$1
    remote_path=$2
    local_path=$3
    key=$(jq -er '.ssh_private_key // empty' "$config_path")
    port=$(vm_field "$platform" port)
    if [ -n "$key" ]; then
        scp -i "$key" -P "$port" -o BatchMode=yes -o ConnectTimeout=10 \
            "$(guest_target "$platform"):$remote_path" "$local_path"
    else
        scp -P "$port" -o BatchMode=yes -o ConnectTimeout=10 \
            "$(guest_target "$platform"):$remote_path" "$local_path"
    fi
}

guest_windows_powershell() {
    guest_ssh "$1" "powershell.exe -NoProfile -NonInteractive -Command \"$2\""
}

wait_for_ssh() {
    platform=$1
    timeout=$(watchdog_seconds ssh 120)
    poll=$(poll_seconds)
    elapsed=0
    while [ "$elapsed" -lt "$timeout" ]; do
        if [ "$platform" = windows ]; then
            probe='powershell.exe -NoProfile -NonInteractive -Command "exit 0"'
        else
            probe=true
        fi
        if guest_ssh "$platform" "$probe" >/dev/null 2>&1; then
            return 0
        fi
        sleep "$poll"
        elapsed=$((elapsed + poll))
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
            provider_exec_current_user "$(vm_name "$platform")" \
                powershell.exe -NoProfile -ExecutionPolicy Bypass -File \
                "$(vm_field "$platform" relay_script)" \
                -Spool "$spool" \
                -RepositoryRoot "$(vm_field "$platform" relay_repository_root)" \
                -AdapterRoot "$(vm_field "$platform" adapter_root)" \
                -Platform windows
            ;;
        *)
            guest_scp "$platform" "$temporary_root/job.json" "$spool/jobs/.$run_id.partial"
            guest_ssh "$platform" "mv '$spool/jobs/.$run_id.partial' '$spool/jobs/$run_id.json'"
            ;;
    esac
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
    elapsed=0
    phase=
    phase_elapsed=0
    while [ "$elapsed" -lt "$overall" ]; do
        if result=$(read_result "$platform" "$run_id" 2>/dev/null); then
            status=$(printf '%s' "$result" | jq -er '.status')
            current_phase=$(printf '%s' "$result" | jq -er '.phase')
            if [ "$status" = running ]; then
                if [ "$current_phase" != "$phase" ]; then
                    phase=$current_phase
                    phase_elapsed=0
                else
                    phase_elapsed=$((phase_elapsed + poll))
                fi
                case "$phase" in
                    queued|preflight) deadline=$(watchdog_seconds readiness 180) ;;
                    checkout) deadline=$(watchdog_seconds checkout 300) ;;
                    adapter) deadline=$(watchdog_seconds adapter 1800) ;;
                    *) vm_evidence_die "relay reported unsupported phase: $phase" ;;
                esac
                [ "$phase_elapsed" -lt "$deadline" ] ||
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
        elapsed=$((elapsed + poll))
    done
    vm_evidence_die "$platform relay did not finish within ${overall} seconds"
}

cleanup_run() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    set +e
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

interaction_driver_root() {
    vm_field "$1" interaction_driver_root
}

interaction_artifact_root() {
    vm_field "$1" interaction_artifact_root
}

interaction_require_running() {
    platform=$1
    name=$(vm_name "$platform")
    provider_vm_exists "$name" || vm_evidence_die "VM not found: $name"
    provider_vm_running "$name" ||
        vm_evidence_die "$platform VM is not running; interactive control never starts it"
}

install_interaction_driver() (
    platform=$1
    lock_path="$(jq -er '.artifact_root' "$config_path")/.locks/lab"
    vm_evidence_acquire_lock "$lock_path"
    trap 'vm_evidence_release_lock "$lock_path"' EXIT
    trap 'exit 130' HUP INT TERM
    interaction_require_running "$platform"
    root=$(interaction_driver_root "$platform")
    case "$platform" in
        linux)
            guest_ssh "$platform" "mkdir -p '$root' '$(interaction_artifact_root "$platform")'"
            guest_scp "$platform" "$repository_root/interaction/linux/driver.py" "$root/.driver.py.partial"
            guest_scp "$platform" "$repository_root/interaction/linux/driver.sh" "$root/.driver.sh.partial"
            guest_ssh "$platform" \
                "mv '$root/.driver.py.partial' '$root/driver.py'; mv '$root/.driver.sh.partial' '$root/driver.sh'; chmod 700 '$root/driver.py' '$root/driver.sh'; '$root/driver.sh' --self-test >/dev/null"
            ;;
        macos)
            source_root="$root/source"
            guest_ssh "$platform" "mkdir -p '$source_root' '$(interaction_artifact_root "$platform")'"
            for file in Models.swift Driver.swift main.swift Info.plist build.sh driver-command.sh; do
                guest_scp "$platform" "$repository_root/interaction/macos/$file" \
                    "$source_root/.$file.partial"
                guest_ssh "$platform" "mv '$source_root/.$file.partial' '$source_root/$file'"
            done
            guest_ssh "$platform" \
                "chmod 700 '$source_root/build.sh' '$source_root/driver-command.sh'; '$source_root/build.sh' '$root/build' >/dev/null; rm -rf '$root/FesTermVMEvidenceInteraction.app'; mv '$root/build/FesTermVMEvidenceInteraction.app' '$root/FesTermVMEvidenceInteraction.app'; cp '$source_root/driver-command.sh' '$root/driver-command.sh'; chmod 700 '$root/driver-command.sh'; '$root/FesTermVMEvidenceInteraction.app/Contents/MacOS/FesTermVMEvidenceInteraction' --self-test >/dev/null"
            ;;
        windows)
            guest_ssh "$platform" \
                "powershell.exe -NoProfile -NonInteractive -Command \"New-Item -ItemType Directory -Force -Path '$root','$(interaction_artifact_root "$platform")' | Out-Null\""
            guest_scp "$platform" "$repository_root/interaction/windows/driver.ps1" \
                "$root\\.driver.ps1.partial"
            guest_windows_powershell "$platform" \
                "\$ErrorActionPreference='Stop'; Move-Item -LiteralPath '$root\\.driver.ps1.partial' -Destination '$root\\driver.ps1' -Force; & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '$root\\driver.ps1' -SelfTest | Out-Null; if (\$LASTEXITCODE -ne 0) { exit \$LASTEXITCODE }"
            ;;
    esac
    printf 'interaction driver installed for %s at %s\n' "$platform" "$root"
)

run_interaction() (
    platform=$1
    session=$2
    command=$3
    output_directory=$4
    vm_evidence_validate_platform "$platform"
    [ -f "$session" ] && [ -f "$command" ] ||
        vm_evidence_die "interaction session and command must be regular files"
    [ ! -e "$output_directory" ] ||
        vm_evidence_die "interaction output directory must be fresh"
    lock_path="$(jq -er '.artifact_root' "$config_path")/.locks/lab"
    vm_evidence_acquire_lock "$lock_path"
    remote_session=
    remote_command=
    # shellcheck disable=SC2329
    cleanup_interaction_request() {
        set +e
        if [ -n "$remote_session" ] && [ -n "$remote_command" ]; then
            case "$platform" in
                windows)
                    guest_windows_powershell "$platform" \
                        "Remove-Item -LiteralPath '$remote_session','$remote_command' -Force -ErrorAction SilentlyContinue" \
                        >/dev/null 2>&1
                    ;;
                *)
                    guest_ssh "$platform" "rm -f '$remote_session' '$remote_command'" \
                        >/dev/null 2>&1
                    ;;
            esac
        fi
        vm_evidence_release_lock "$lock_path"
    }
    trap cleanup_interaction_request EXIT
    trap 'exit 130' HUP INT TERM
    "$python_command" "$repository_root/host/interactive.py" \
        --validate-request --session "$session" --command "$command" >/dev/null
    interaction_require_running "$platform"
    session_id=$(jq -er '.session_id' "$session")
    sequence=$(jq -er '.sequence' "$command")
    maximum_commands=$(jq -er '.limits.maximum_commands' "$session")
    state_root="$(jq -er '.artifact_root' "$config_path")/.interaction-state"
    sequence_file="$state_root/$platform-$session_id.sequence"
    mkdir -p "$state_root"
    if [ -f "$sequence_file" ]; then
        state=$(cat "$sequence_file")
        case "$state" in
            "ready "*)
                expected_sequence=${state#ready }
                ;;
            "inflight "*)
                vm_evidence_die "interaction session $session_id has an indeterminate in-flight command; use a new session"
                ;;
            *)
                vm_evidence_die "interaction session $session_id has corrupt sequence state"
                ;;
        esac
    else
        expected_sequence=1
    fi
    [ "$sequence" -eq "$expected_sequence" ] ||
        vm_evidence_die "interaction session $session_id expected sequence $expected_sequence, received $sequence"
    [ "$sequence" -le "$maximum_commands" ] ||
        vm_evidence_die "interaction session $session_id exhausted its command bound"
    printf 'inflight %s\n' "$sequence" >"$sequence_file.partial"
    mv "$sequence_file.partial" "$sequence_file"
    request_id="interactive-$(uuidgen | tr '[:upper:]' '[:lower:]')"
    case "$platform" in
        windows)
            remote_session="$(vm_field "$platform" relay_spool)\\interactions\\$request_id.session.json"
            remote_command="$(vm_field "$platform" relay_spool)\\interactions\\$request_id.command.json"
            ;;
        *)
            remote_session="$(vm_field "$platform" relay_spool)/interactions/$request_id.session.json"
            remote_command="$(vm_field "$platform" relay_spool)/interactions/$request_id.command.json"
            ;;
    esac
    mkdir -p "$output_directory"
    case "$platform" in
        windows)
            guest_ssh "$platform" \
                "powershell.exe -NoProfile -NonInteractive -Command \"New-Item -ItemType Directory -Force -Path '$(vm_field "$platform" relay_spool)\\interactions' | Out-Null\""
            ;;
        *)
            guest_ssh "$platform" "mkdir -p '$(vm_field "$platform" relay_spool)/interactions'"
            ;;
    esac
    guest_scp "$platform" "$session" "$remote_session"
    guest_scp "$platform" "$command" "$remote_command"
    host_result="$output_directory/result.json"
    root=$(interaction_driver_root "$platform")
    artifact_root=$(interaction_artifact_root "$platform")
    timeout_ms=$(jq -er '.limits.command_timeout_ms' "$session")
    key=$(jq -er '.ssh_private_key // empty' "$config_path")
    port=$(vm_field "$platform" port)
    case "$platform" in
        linux)
            remote_interaction="systemd-run --user --wait --pipe --collect --quiet '$root/driver.sh' --session '$remote_session' --command '$remote_command' --artifact-directory '$artifact_root'"
            if [ -n "$key" ]; then
                "$python_command" "$repository_root/host/bounded_exec.py" \
                    --timeout-ms "$timeout_ms" -- \
                    ssh -i "$key" -p "$port" -o BatchMode=yes -o ConnectTimeout=10 \
                    "$(guest_target "$platform")" "$remote_interaction" >"$host_result"
            else
                "$python_command" "$repository_root/host/bounded_exec.py" \
                    --timeout-ms "$timeout_ms" -- \
                    ssh -p "$port" -o BatchMode=yes -o ConnectTimeout=10 \
                    "$(guest_target "$platform")" "$remote_interaction" >"$host_result"
            fi
            ;;
        macos)
            # The guest wrapper enforces the operation budget plus bounded LS
            # startup/child cleanup. Keep the host alive until that cleanup ends.
            mac_transport_timeout_ms=$((timeout_ms + 15000))
            "$python_command" "$repository_root/host/bounded_exec.py" \
                --timeout-ms "$mac_transport_timeout_ms" -- \
                prlctl exec "$(vm_name "$platform")" --current-user \
                "$root/driver-command.sh" "$remote_session" "$remote_command" "$artifact_root" \
                >"$host_result"
            ;;
        windows)
            "$python_command" "$repository_root/host/bounded_exec.py" \
                --timeout-ms "$timeout_ms" -- \
                prlctl exec "$(vm_name "$platform")" --current-user \
                powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \
                "$root\\driver.ps1" -SessionPath "$remote_session" \
                -CommandPath "$remote_command" -ArtifactDirectory "$artifact_root" \
                >"$host_result"
            ;;
    esac
    "$python_command" "$repository_root/host/interactive.py" \
        --validate-result "$host_result" \
        --session "$session" --command "$command" >/dev/null
    guest_root=$artifact_root
    # TSV escapes Windows backslashes; keep each validated artifact as JSON.
    jq -r '.artifacts[] | @base64' "$host_result" |
    while IFS= read -r artifact_row; do
        artifact_json=$(printf '%s' "$artifact_row" | jq -Rr '@base64d')
        name=$(printf '%s' "$artifact_json" | jq -r '.name')
        path=$(printf '%s' "$artifact_json" | jq -r '.path')
        size=$(printf '%s' "$artifact_json" | jq -r '.size')
        digest=$(printf '%s' "$artifact_json" | jq -r '.sha256')
        case "$platform" in
            windows)
                [ "$path" = "$guest_root\\$name" ] ||
                    [ "$path" = "$guest_root\\$name.png" ] ||
                    vm_evidence_die "driver reported an unexpected artifact path"
                ;;
            *)
                [ "$path" = "$guest_root/$name" ] ||
                    [ "$path" = "$guest_root/$name.png" ] ||
                    vm_evidence_die "driver reported an unexpected artifact path"
                ;;
        esac
        mkdir -p "$output_directory/artifacts"
        local_artifact="$output_directory/artifacts/$name"
        scp_path=$path
        if [ "$platform" = windows ]; then
            # OpenSSH's remote path uses forward slashes; validate native paths above.
            scp_path=$(printf '%s' "$path" | sed 's,\\,/,g')
        fi
        guest_scp_from "$platform" "$scp_path" "$local_artifact"
        "$python_command" - "$local_artifact" "$size" "$digest" <<'PY'
import hashlib
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
expected_size = int(sys.argv[2])
expected_digest = sys.argv[3]
digest = hashlib.sha256()
actual_size = 0
with path.open("rb") as stream:
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        actual_size += len(block)
        digest.update(block)
if actual_size != expected_size or digest.hexdigest() != expected_digest:
    raise SystemExit("copied artifact does not match guest result metadata")
PY
    done
    printf 'ready %s\n' "$((sequence + 1))" >"$sequence_file.partial"
    mv "$sequence_file.partial" "$sequence_file"
    printf '%s\n' "$host_result"
    jq -e '.status == "pass"' "$host_result" >/dev/null ||
        vm_evidence_die "interaction command did not pass; validated result retained in $host_result"
)

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
    vm_evidence_acquire_lock "$lock_path"
    [ ! -e "$run_root" ] || vm_evidence_die "run directory exists: $run_root"
    mkdir -p "$run_root"
    run_platform=$platform
    run_started=0
    trap cleanup_run EXIT HUP INT TERM

    reset_vm "$platform"
    provider_wait_for_restore "$(vm_name "$platform")" "$(watchdog_seconds restore 120)"
    provider_start "$(vm_name "$platform")"
    run_started=1
    wait_for_ssh "$platform"
    requested_relay_sha=$(relay_sha)
    sync_relay "$platform" "$requested_relay_sha"
    sync_adapter "$platform" "$adapter_id"
    quarantine_stale_jobs "$platform"
    capture_vm "$platform" "$run_root/desktop-ready.png"
    publish_job "$platform" "$request" "$run_id" "$temporary_root"
    result=$(wait_for_result "$platform" "$run_id")
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
  controller.sh interaction-capabilities <windows|linux|macos>
  controller.sh interaction-install <windows|linux|macos>
  controller.sh interaction-dry-run <session.json> <command.json>
  controller.sh interaction <windows|linux|macos> <session.json> <command.json> <fresh-output-dir>
  controller.sh run <windows|linux|macos> <host-request.json>
  controller.sh all <host-request.json>
EOF
    exit 2
}

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
    interaction-capabilities)
        [ "$#" -eq 2 ] || usage
        vm_evidence_validate_platform "$2"
        provider_interaction_capabilities
        ;;
    interaction-install)
        [ "$#" -eq 2 ] || usage
        vm_evidence_validate_platform "$2"
        install_interaction_driver "$2"
        ;;
    interaction-dry-run)
        [ "$#" -eq 3 ] || usage
        "$python_command" "$repository_root/host/interactive.py" \
            --dry-run --session "$2" --command "$3"
        ;;
    interaction)
        [ "$#" -eq 5 ] || usage
        run_interaction "$2" "$3" "$4" "$5"
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
