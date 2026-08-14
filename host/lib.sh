#!/usr/bin/env sh
set -eu

vm_evidence_die() {
    printf 'vm-evidence: %s\n' "$*" >&2
    exit 2
}

vm_evidence_require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        vm_evidence_die "required command not found: $1"
}

vm_evidence_validate_sha() {
    printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$|^[0-9a-f]{64}$' ||
        vm_evidence_die 'source SHA must be a full lowercase 40- or 64-character object ID.'
}

vm_evidence_validate_identifier() {
    printf '%s' "$1" | grep -Eq '^[a-z][a-z0-9-]{0,63}$' ||
        vm_evidence_die "invalid identifier: $1"
}

vm_evidence_validate_platform() {
    case "$1" in
        windows|linux|macos) ;;
        *) vm_evidence_die "unknown platform: $1" ;;
    esac
}

vm_evidence_acquire_lock() {
    lock_path=$1
    mkdir -p "$(dirname -- "$lock_path")"
    if ! mkdir "$lock_path" 2>/dev/null; then
        if [ ! -f "$lock_path/pid" ] ||
           ! kill -0 "$(cat "$lock_path/pid")" 2>/dev/null; then
            rm -f "$lock_path/pid"
            rmdir "$lock_path" 2>/dev/null ||
                vm_evidence_die "stale lock cannot be removed: $lock_path"
            mkdir "$lock_path" ||
                vm_evidence_die "cannot acquire lock: $lock_path"
        else
            vm_evidence_die "$(basename "$lock_path") already has an active run"
        fi
    fi
    printf '%s\n' "$$" >"$lock_path/pid"
}

vm_evidence_release_lock() {
    lock_path=$1
    rm -f "$lock_path/pid"
    rmdir "$lock_path" 2>/dev/null || true
}

vm_evidence_atomic_write() {
    destination=$1
    temporary="$destination.partial"
    cat >"$temporary"
    mv "$temporary" "$destination"
}

vm_evidence_full_sha() {
    repository=$1
    requested=$2
    vm_evidence_validate_sha "$requested"
    resolved=$(git -C "$repository" rev-parse "$requested^{commit}") ||
        vm_evidence_die "source SHA is unavailable in $repository: $requested"
    [ "$resolved" = "$requested" ] ||
        vm_evidence_die "source SHA did not resolve exactly in $repository: $requested"
    printf '%s\n' "$resolved"
}

vm_evidence_bundle_name() {
    run_id=$1
    source_id=$2
    digest=$(printf '%s\n%s\n' "$run_id" "$source_id" | git hash-object --stdin) ||
        vm_evidence_die 'could not derive source bundle name'
    printf '%s.bundle\n' "$digest"
}

vm_evidence_create_bundle() {
    repository=$1
    requested_sha=$2
    destination=$3
    staging_repository=$4
    vm_evidence_full_sha "$repository" "$requested_sha" >/dev/null
    git init -q --bare "$staging_repository" ||
        vm_evidence_die "could not create bundle staging repository: $staging_repository"
    git --git-dir="$staging_repository" fetch -q --no-tags "$repository" "$requested_sha" ||
        vm_evidence_die "could not stage source commit: $requested_sha"
    git --git-dir="$staging_repository" update-ref refs/heads/evidence FETCH_HEAD ||
        vm_evidence_die "could not create source bundle reference: $requested_sha"
    git --git-dir="$staging_repository" bundle create "$destination" refs/heads/evidence ||
        vm_evidence_die "could not create source bundle: $requested_sha"
}
