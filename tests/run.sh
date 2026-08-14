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
)
grep -qx 'start evidence-linux' "$work/provider.log"
grep -qx 'snapshot-switch evidence-linux --id snapshot-1' "$work/provider.log"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$root/host/controller.sh" "$root/host/lib.sh" \
        "$root/providers/parallels.sh" "$root/relay/common.sh" \
        "$root/relay/unix.sh" "$root/relay/install-linux.sh" \
        "$root/relay/install-macos.sh" "$root/tests/run.sh"
fi

echo 'Unix contract tests passed.'
