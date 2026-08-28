#!/usr/bin/env sh
set -eu

root=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
work="$root/.test-work/unix"
rm -rf "$work"
mkdir -p "$work/bin" "$work/spool/jobs" "$work/spool/bundles" \
    "$work/repositories" "$work/adapters/fake"

cleanup() {
    rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

python_command=${PYTHON:-python3}
for command in git jq "$python_command"; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "required test command not found: $command" >&2
        exit 2
    }
done

"$python_command" "$root/tests/test_contract.py"
"$root/host/validate-host-input.sh" "$root/tests/fixtures/host-input-valid.json"
jq '.stages[0].events[1].code = 1' \
    "$root/tests/fixtures/host-input-valid.json" >"$work/invalid-host-input.json"
if "$root/host/validate-host-input.sh" "$work/invalid-host-input.json"; then
    echo 'host-input validation accepted a wildcard key code' >&2
    exit 1
fi
jq '.unexpected = true' "$root/tests/fixtures/host-input-valid.json" \
    >"$work/invalid-host-input.json"
if "$root/host/validate-host-input.sh" "$work/invalid-host-input.json"; then
    echo 'host-input validation accepted an unknown field' >&2
    exit 1
fi

cp "$root/tests/fixtures/fake-adapter/policy.json" "$work/adapters/fake/policy.json"
cp "$root/tests/fixtures/fake-adapter/linux.sh" "$work/adapters/fake/linux.sh"
printf '%040d' 0 >"$work/adapters/fake/adapter-version.txt"
chmod 755 "$work/adapters/fake/linux.sh"

git init -q "$work/source"
git -C "$work/source" config user.name vm-evidence-test
git -C "$work/source" config user.email vm-evidence-test@example.invalid
printf 'exact source\n' >"$work/source/evidence.txt"
git -C "$work/source" add evidence.txt
git -C "$work/source" commit -qm 'Create test source'
sha=$(git -C "$work/source" rev-parse HEAD)
(
    # shellcheck disable=SC1091
    . "$root/host/lib.sh"
    vm_evidence_create_bundle "$work/source" "$sha" \
        "$work/spool/bundles/pass.bundle" "$work/bundle-source"
)
test "$(git bundle list-heads "$work/spool/bundles/pass.bundle" | wc -l | tr -d ' ')" -eq 1
git bundle list-heads "$work/spool/bundles/pass.bundle" |
    grep -Eq '^[0-9a-f]{40} refs/heads/evidence$'

cat >"$work/spool/jobs/pass.json" <<EOF
{
  "schema_version": 1,
  "run_id": "pass-run",
  "adapter_id": "fake",
  "adapter_sha": "0000000000000000000000000000000000000000",
  "adapter_schema_version": 1,
  "mode": "pass",
  "platform": "linux",
  "sources": [
    {"id": "product", "sha": "$sha", "bundle": "pass.bundle"}
  ],
  "payload": {}
}
EOF

VM_EVIDENCE_SPOOL="$work/spool" \
VM_EVIDENCE_REPOSITORY_ROOT="$work/repositories" \
VM_EVIDENCE_ADAPTER_ROOT="$work/adapters" \
VM_EVIDENCE_PLATFORM=linux \
    "$root/relay/unix.sh"

jq -e --arg sha "$sha" '
  .status == "pass" and .failure_class == null and
  .resolved_sources == [{
    id: "product", requested_sha: $sha, resolved_sha: $sha
  }]
' "$work/spool/results/pass-run.json" >/dev/null
test -f "$work/spool/jobs/processed-pass.json"
test -f "$work/spool/artifacts/pass-run/fake-result.txt"
test ! -e "$work/spool/results/pass-run.json.partial"

sed \
    -e 's/pass-run/adapter-mismatch-run/g' \
    -e 's/0000000000000000000000000000000000000000/1111111111111111111111111111111111111111/' \
    "$work/spool/jobs/processed-pass.json" >"$work/spool/jobs/adapter-mismatch.json"

VM_EVIDENCE_SPOOL="$work/spool" \
VM_EVIDENCE_REPOSITORY_ROOT="$work/repositories" \
VM_EVIDENCE_ADAPTER_ROOT="$work/adapters" \
VM_EVIDENCE_PLATFORM=linux \
    "$root/relay/unix.sh"

jq -e '.status == "fail" and .failure_class == "configuration"' \
    "$work/spool/results/adapter-mismatch-run.json" >/dev/null

cp "$work/spool/bundles/pass.bundle" "$work/spool/bundles/fail.bundle"
sed \
    -e 's/pass-run/fail-run/g' \
    -e 's/"mode": "pass"/"mode": "fail"/' \
    -e 's/pass.bundle/fail.bundle/' \
    "$work/spool/jobs/processed-pass.json" >"$work/spool/jobs/fail.json"

VM_EVIDENCE_SPOOL="$work/spool" \
VM_EVIDENCE_REPOSITORY_ROOT="$work/repositories" \
VM_EVIDENCE_ADAPTER_ROOT="$work/adapters" \
VM_EVIDENCE_PLATFORM=linux \
    "$root/relay/unix.sh"

jq -e '.status == "fail" and .failure_class == "product"' \
    "$work/spool/results/fail-run.json" >/dev/null

(
    # shellcheck disable=SC1091
    . "$root/host/lib.sh"
    long_id=$(printf '%064d' 0)
    bundle_name=$(vm_evidence_bundle_name "$long_id" "$long_id")
    printf '%s' "$bundle_name" | grep -Eq '^[0-9a-f]{40}\.bundle$'

    lock="$work/locks/lab"
    mkdir -p "$lock"
    printf '999999\n' >"$lock/pid"
    vm_evidence_acquire_lock "$lock"
    test "$(cat "$lock/pid")" = "$$"
    vm_evidence_release_lock "$lock"
    test ! -e "$lock"
)

cat >"$work/bin/prlctl" <<'EOF'
#!/usr/bin/env sh
case "$1 $2" in
  "list --all") printf '[{"name":"evidence-linux","status":"stopped"}]\n' ;;
  "list evidence-linux") printf '[{"name":"evidence-linux","status":"stopped"}]\n' ;;
  *) printf '%s\n' "$*" >>"$VM_EVIDENCE_FAKE_PROVIDER_LOG" ;;
esac
EOF
chmod 755 "$work/bin/prlctl"
PATH="$work/bin:$PATH"
export PATH
VM_EVIDENCE_FAKE_PROVIDER_LOG="$work/provider.log"
export VM_EVIDENCE_FAKE_PROVIDER_LOG
(
    # shellcheck disable=SC1091
    . "$root/host/lib.sh"
    # shellcheck disable=SC1091
    . "$root/providers/parallels.sh"
    provider_require
    provider_vm_exists evidence-linux
    provider_start evidence-linux
    provider_reset evidence-linux snapshot-1
    provider_send_input_event evidence-linux key 23
    provider_send_input_event evidence-linux pointer-button 178
)
grep -qx 'start evidence-linux' "$work/provider.log"
grep -qx 'snapshot-switch evidence-linux --id snapshot-1' "$work/provider.log"
grep -qx 'send-key-event evidence-linux --key 23' "$work/provider.log"
grep -qx 'send-key-event evidence-linux --key 178' "$work/provider.log"

(
    VM_EVIDENCE_CONTROLLER_LIBRARY_ONLY=1
    VM_EVIDENCE_CONTROLLER_ROOT="$root/host"
    export VM_EVIDENCE_CONTROLLER_LIBRARY_ONLY
    export VM_EVIDENCE_CONTROLLER_ROOT
    # shellcheck disable=SC1090
    . "$root/host/controller.sh"
    temporary_root="$work"
    host_input_completed=0
    read_result() { return 3; }
    read_host_input_stage() {
        printf '{"schema_version":1,"run_id":"test-run","stage":"%s"}\n' "$3"
    }
    vm_name() { printf 'evidence-windows\n'; }
    provider_send_input_event() {
        printf '%s %s %s\n' "$1" "$2" "$3" >>"$work/host-input-events.log"
    }
    drive_host_input windows test-run "$root/tests/fixtures/host-input-valid.json"
    test "$host_input_completed" -eq 1
)
cat >"$work/expected-host-input-events.log" <<'EOF'
evidence-windows pointer-button 178
evidence-windows key 23
evidence-windows key 98
EOF
cmp "$work/expected-host-input-events.log" "$work/host-input-events.log"

(
    VM_EVIDENCE_CONTROLLER_LIBRARY_ONLY=1
    VM_EVIDENCE_CONTROLLER_ROOT="$root/host"
    export VM_EVIDENCE_CONTROLLER_LIBRARY_ONLY
    export VM_EVIDENCE_CONTROLLER_ROOT
    # shellcheck disable=SC1090
    . "$root/host/controller.sh"
    temporary_root="$work"
    host_input_completed=0
    read_result() { return 3; }
    read_host_input_stage() {
        printf '{"schema_version":1,"run_id":"test-run","stage":"%s"}\n' "$3"
    }
    vm_name() { printf 'evidence-windows\n'; }
    provider_send_input_event() { [ "$3" -ne 23 ]; }
    if drive_host_input windows test-run "$root/tests/fixtures/host-input-valid.json"; then
        echo 'host-input driver ignored an event failure' >&2
        exit 1
    fi
    test "$host_input_completed" -eq 0
)

deadline_started=$(date +%s)
if (
    VM_EVIDENCE_CONTROLLER_LIBRARY_ONLY=1
    VM_EVIDENCE_CONTROLLER_ROOT="$root/host"
    export VM_EVIDENCE_CONTROLLER_LIBRARY_ONLY
    export VM_EVIDENCE_CONTROLLER_ROOT
    # shellcheck disable=SC1090
    . "$root/host/controller.sh"
    temporary_root="$work/deadline"
    mkdir -p "$temporary_root"
    poll_seconds() { printf '2\n'; }
    read_result() {
        sleep 2
        return 3
    }
    read_host_input_stage() { return 3; }
    wait_for_host_input_stage windows test-run ready 3
) 2>"$work/deadline-error.log"; then
    echo 'host-input stage ignored its absolute deadline' >&2
    exit 1
fi
deadline_elapsed=$(($(date +%s) - deadline_started))
test "$deadline_elapsed" -ge 3
test "$deadline_elapsed" -lt 7
grep -q 'host-input stage timed out: ready' "$work/deadline-error.log"

mkdir -p "$work/early-exit"
printf '0\n' >"$work/early-exit/relay-activation.status"
early_exit_started=$(date +%s)
if (
    VM_EVIDENCE_CONTROLLER_LIBRARY_ONLY=1
    VM_EVIDENCE_CONTROLLER_ROOT="$root/host"
    export VM_EVIDENCE_CONTROLLER_LIBRARY_ONLY
    export VM_EVIDENCE_CONTROLLER_ROOT
    # shellcheck disable=SC1090
    . "$root/host/controller.sh"
    temporary_root="$work/early-exit"
    poll_seconds() { printf '2\n'; }
    read_result() {
        printf '{"status":"running","phase":"adapter"}\n'
    }
    read_host_input_stage() { return 3; }
    wait_for_host_input_stage windows test-run ready 30
) 2>"$work/early-exit-error.log"; then
    echo 'host-input stage ignored an exited graphical relay' >&2
    exit 1
fi
early_exit_elapsed=$(($(date +%s) - early_exit_started))
test "$early_exit_elapsed" -lt 5
grep -q 'relay exited before host-input stage: ready' "$work/early-exit-error.log"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$root/host/controller.sh" "$root/host/lib.sh" \
        "$root/host/validate-host-input.sh" \
        "$root/providers/parallels.sh" "$root/relay/common.sh" \
        "$root/relay/unix.sh" "$root/relay/install-linux.sh" \
        "$root/relay/install-macos.sh" "$root/tests/run.sh"
fi

echo 'Unix contract tests passed.'
