#!/usr/bin/env sh
set -eu

relay_root=${VM_EVIDENCE_SPOOL:?VM_EVIDENCE_SPOOL is required}
relay_repository_root=${VM_EVIDENCE_REPOSITORY_ROOT:?VM_EVIDENCE_REPOSITORY_ROOT is required}
relay_adapter_root=${VM_EVIDENCE_ADAPTER_ROOT:?VM_EVIDENCE_ADAPTER_ROOT is required}
relay_platform=${VM_EVIDENCE_PLATFORM:?VM_EVIDENCE_PLATFORM is required}
PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
export PATH

relay_die() {
    printf 'vm-evidence relay: %s\n' "$*" >&2
    exit 2
}

relay_validate_job() {
    job_path=$1
    jq -e '
        (keys | sort) ==
          (["adapter_id", "adapter_sha", "adapter_schema_version", "mode", "payload",
            "platform", "run_id", "schema_version", "sources"] | sort) and
        .schema_version == 1 and
        (.run_id | type == "string" and test("^[A-Za-z0-9._-]{1,128}$")) and
        (.adapter_id | type == "string" and test("^[a-z][a-z0-9-]{0,63}$")) and
        (.adapter_sha | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
        (.adapter_schema_version | type == "number" and . >= 1 and floor == .) and
        (.mode | type == "string" and test("^[a-z][a-z0-9-]{0,63}$")) and
        (.platform == "windows" or .platform == "linux" or .platform == "macos") and
        (.sources | type == "array" and length <= 8) and
        ([.sources[].id] | length == (unique | length)) and
        ([.sources[].bundle] | length == (unique | length)) and
        (all(.sources[];
          (keys | sort) == (["bundle", "id", "sha"] | sort) and
          (.id | type == "string" and test("^[a-z][a-z0-9-]{0,63}$")) and
          (.sha | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
          (.bundle | type == "string" and test("^[A-Za-z0-9._-]{1,128}\\.bundle$"))
        )) and
        (.payload | type == "object")
    ' "$job_path" >/dev/null
}

relay_validate_policy() {
    job_path=$1
    adapter_id=$(jq -er '.adapter_id' "$job_path")
    [ "$adapter_id" = infrastructure ] && return 0
    policy_path="$relay_adapter_root/$adapter_id/policy.json"
    version_path="$relay_adapter_root/$adapter_id/adapter-version.txt"
    [ -f "$policy_path" ] || return 1
    [ -f "$version_path" ] || return 1
    [ "$(tr -d '\r\n' <"$version_path")" = "$(jq -er '.adapter_sha' "$job_path")" ] ||
        return 1
    jq -e --slurpfile job "$job_path" '
        (keys | sort) ==
          (["adapter_id", "modes", "platforms", "schema_version"] | sort) and
        .adapter_id == $job[0].adapter_id and
        .schema_version == $job[0].adapter_schema_version and
        (.modes | index($job[0].mode)) != null and
        (.platforms | index($job[0].platform)) != null
    ' "$policy_path" >/dev/null
}

relay_write_result() {
    status=$1
    phase=$2
    failure_class=$3
    message=$4
    temporary_path="$result_path.partial"
    jq -n \
        --argjson schema_version 1 \
        --arg run_id "$run_id" \
        --arg status "$status" \
        --arg phase "$phase" \
        --arg failure_class "$failure_class" \
        --arg message "$message" \
        --arg adapter_id "$adapter_id" \
        --arg adapter_sha "$adapter_sha" \
        --argjson adapter_schema_version "$adapter_schema_version" \
        --arg mode "$mode" \
        --arg platform "$relay_platform" \
        --argjson resolved_sources "${resolved_sources:-[]}" \
        --arg updated_at "$(date -u +%FT%TZ)" \
        '{
          schema_version: $schema_version,
          run_id: $run_id,
          status: $status,
          phase: $phase,
          failure_class: (if $failure_class == "" then null else $failure_class end),
          message: $message,
          adapter_id: $adapter_id,
          adapter_sha: $adapter_sha,
          adapter_schema_version: $adapter_schema_version,
          mode: $mode,
          platform: $platform,
          resolved_sources: $resolved_sources,
          updated_at: $updated_at
        }' >"$temporary_path" &&
        mv "$temporary_path" "$result_path"
}

relay_stage_sources() {
    source_map_path=$1
    resolved_sources='[]'
    source_map='[]'
    relay_write_result running checkout '' 'staging exact source revisions'
    jq -c '.sources[]' "$job_path" |
    while IFS= read -r source; do
        source_id=$(printf '%s' "$source" | jq -er '.id')
        requested_sha=$(printf '%s' "$source" | jq -er '.sha')
        bundle_name=$(printf '%s' "$source" | jq -er '.bundle')
        bundle_path="$relay_root/bundles/$bundle_name"
        checkout_path="$relay_repository_root/$source_id"
        [ -f "$bundle_path" ] || exit 21
        if [ ! -d "$checkout_path/.git" ]; then
            git clone "$bundle_path" "$checkout_path" >/dev/null 2>&1 || exit 22
        else
            git -C "$checkout_path" fetch "$bundle_path" "$requested_sha" >/dev/null 2>&1 ||
                exit 22
        fi
        git -C "$checkout_path" checkout --detach --force "$requested_sha" >/dev/null 2>&1 ||
            exit 23
        resolved_sha=$(git -C "$checkout_path" rev-parse HEAD) || exit 23
        [ "$resolved_sha" = "$requested_sha" ] || exit 24
        printf '%s\t%s\t%s\n' "$source_id" "$requested_sha" "$checkout_path"
    done >"$source_map_path.rows" || {
        rm -f "$source_map_path.rows"
        return 1
    }

    while IFS="$(printf '\t')" read -r source_id requested_sha checkout_path; do
        resolved_sources=$(printf '%s' "$resolved_sources" |
            jq --arg id "$source_id" --arg requested "$requested_sha" \
                '. + [{id: $id, requested_sha: $requested, resolved_sha: $requested}]')
        source_map=$(printf '%s' "$source_map" |
            jq --arg id "$source_id" --arg sha "$requested_sha" --arg path "$checkout_path" \
                '. + [{id: $id, sha: $sha, path: $path}]')
    done <"$source_map_path.rows"
    rm -f "$source_map_path.rows"
    printf '%s\n' "$source_map" >"$source_map_path.partial"
    mv "$source_map_path.partial" "$source_map_path"
}

relay_execute_job() {
    source_map_path="$artifact_path/source-map.json"
    relay_write_result running preflight '' 'validating installed adapter policy'
    if ! command -v git >/dev/null || ! command -v jq >/dev/null; then
        failure_class=provisioning
        return 1
    fi
    [ "$relay_platform" = "$(jq -er '.platform' "$job_path")" ] || {
        failure_class=configuration
        return 1
    }
    relay_validate_policy "$job_path" || {
        failure_class=configuration
        return 1
    }

    if [ "$adapter_id" = infrastructure ] && [ "$mode" = readiness-probe ]; then
        [ "$(jq -er '.sources | length' "$job_path")" -eq 0 ] || {
            failure_class=configuration
            return 1
        }
        return 0
    fi

    relay_stage_sources "$source_map_path" || {
        failure_class=artifact
        return 1
    }
    adapter_path="$relay_adapter_root/$adapter_id/$relay_platform.sh"
    [ -f "$adapter_path" ] && [ -x "$adapter_path" ] || {
        failure_class=configuration
        return 1
    }
    relay_write_result running adapter '' 'running installed product adapter'
    if "$adapter_path" "$job_path" "$source_map_path" "$artifact_path"; then
        return 0
    fi
    failure_class=product
    return 1
}

relay_run_job() {
    job_path=$1
    relay_validate_job "$job_path" || return 2
    run_id=$(jq -er '.run_id' "$job_path")
    adapter_id=$(jq -er '.adapter_id' "$job_path")
    adapter_sha=$(jq -er '.adapter_sha' "$job_path")
    adapter_schema_version=$(jq -er '.adapter_schema_version' "$job_path")
    mode=$(jq -er '.mode' "$job_path")
    result_path="$relay_root/results/$run_id.json"
    log_path="$relay_root/logs/$run_id.log"
    artifact_path="$relay_root/artifacts/$run_id"
    resolved_sources='[]'
    failure_class=
    [ ! -e "$result_path" ] || return 3
    mkdir -p "$artifact_path"
    relay_write_result running queued '' 'relay accepted job'
    if relay_execute_job >"$log_path" 2>&1; then
        relay_write_result pass complete '' 'adapter evidence passed'
    else
        relay_write_result fail complete "${failure_class:-infrastructure}" \
            "evidence failed; inspect $log_path"
    fi
}

relay_process_jobs() {
    lock_root="$relay_root/jobs/.locks"
    mkdir -p "$relay_root/jobs" "$relay_root/bundles" "$relay_root/logs" \
        "$relay_root/results" "$relay_root/artifacts" "$lock_root" "$relay_repository_root"
    find "$relay_root/jobs" -maxdepth 1 -type f -name '*.json' \
        ! -name '.running-*' ! -name 'processed-*' ! -name 'rejected-*' \
        ! -name 'infrastructure-failed-*' -print | sort |
    while IFS= read -r queued_path; do
        job_name=$(basename "$queued_path")
        lock_path="$lock_root/$job_name"
        claimed_path="$relay_root/jobs/.running-$job_name"
        mkdir "$lock_path" 2>/dev/null || continue
        if ! mv "$queued_path" "$claimed_path" 2>/dev/null; then
            rmdir "$lock_path"
            continue
        fi
        if relay_run_job "$claimed_path"; then
            destination="$relay_root/jobs/processed-$job_name"
        else
            destination="$relay_root/jobs/rejected-$job_name"
        fi
        mv "$claimed_path" "$destination"
        rmdir "$lock_path"
    done
}
