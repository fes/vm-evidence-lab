#!/usr/bin/env sh
set -eu
umask 077

[ "$#" -eq 3 ] || {
    echo "usage: $0 <session.json> <command.json> <artifact-root>" >&2
    exit 2
}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
app="$script_dir/FesTermVMEvidenceInteraction.app"
driver="$app/Contents/MacOS/FesTermVMEvidenceInteraction"
[ -x "$driver" ] && [ ! -L "$app" ] && [ ! -L "$driver" ] || {
    echo "macOS interaction driver is not installed" >&2
    exit 69
}
# The canonical host already validates these JSON documents; preserve its 4 MiB
# transport cap here too, without interpreting command text as shell syntax.
for input in "$1" "$2"; do
    [ -f "$input" ] && [ ! -L "$input" ] || exit 2
    [ "$(wc -c <"$input")" -le 4194304 ] || exit 65
done
/usr/bin/codesign --verify --deep --strict "$app"
timeout_ms=$(/usr/bin/plutil -extract limits.command_timeout_ms raw -o - "$1")
case "$timeout_ms" in ''|*[!0-9]*) exit 2 ;; esac
[ "$timeout_ms" -ge 100 ] && [ "$timeout_ms" -le 120000 ] || exit 2
# LaunchServices owns the GUI/TCC responsibility. Direct execution inherits the
# remote transport's responsibility even when this exact app has been granted AX.
work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/vm-evidence-interaction.XXXXXXXX")
chmod 700 "$work"
cp "$1" "$work/session.json"
cp "$2" "$work/command.json"
: >"$work/result.json"
: >"$work/error.log"
chmod 600 "$work/session.json" "$work/command.json" "$work/result.json" "$work/error.log"
uid=$(id -u)
open_pid=
# ps output is never emitted: only the exact helper executable's public argv is
# inspected, and a unique private session path distinguishes this invocation.
helper_rows() {
    /bin/ps -ww -axo pid=,comm= | while read -r candidate executable; do
        [ "$executable" = "$driver" ] || continue
        printf '%s\n' "$candidate"
    done
}
identity() {
    candidate=$1
    [ "$(/bin/ps -p "$candidate" -o uid= | tr -d ' ')" = "$uid" ] || return 1
    [ "$(/bin/ps -ww -p "$candidate" -o comm=)" = "$driver" ] || return 1
    [ "$(/bin/ps -ww -p "$candidate" -o command=)" = "$driver --session $work/session.json --artifact-root $artifact_root" ] || return 1
    /bin/ps -p "$candidate" -o lstart=
}
# Retain the artifact argument separately from function positional arguments.
artifact_root=$3
remember_children() {
    for candidate in $(helper_rows); do
        birth=$(identity "$candidate") || continue
        [ -n "$birth" ] || continue
        if [ ! -e "$work/child.$candidate" ]; then
            printf '%s\n' "$birth" >"$work/child.$candidate"
        fi
    done
}
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    remember_children
    for record in "$work"/child.*; do
        [ -f "$record" ] || continue
        candidate=${record##*.}
        birth=$(identity "$candidate") || continue
        if [ "$birth" = "$(cat "$record")" ]; then
            kill -TERM "$candidate" 2>/dev/null || :
        fi
    done
    # A LaunchServices child is outside open's process group. Its absence, not
    # merely open's exit, is the cleanup condition. Never kill a reused PID.
    cleanup_deadline=$(( $(date +%s) + 3 ))
    while :; do
        remaining=$(helper_rows)
        [ -z "$remaining" ] && break
        [ "$(date +%s)" -lt "$cleanup_deadline" ] || break
        sleep 0.1
    done
    if [ -n "$open_pid" ]; then
        kill -TERM "$open_pid" 2>/dev/null || :
        wait "$open_pid" 2>/dev/null || :
    fi
    if [ -n "${remaining:-}" ]; then
        echo "macOS interaction helper cleanup could not verify absence; private evidence retained" >&2
        exit 125
    fi
    rm -rf "$work"
    exit "$status"
}
[ -z "$(helper_rows)" ] || {
    echo "macOS interaction helper is already running; refusing concurrent adoption" >&2
    rm -rf "$work"
    exit 75
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/open -n -g -W --stdin "$work/command.json" \
    --stdout "$work/result.json" --stderr "$work/error.log" -a "$app" \
    --args --session "$work/session.json" --artifact-root "$artifact_root" &
open_pid=$!
deadline=$(( $(date +%s) + (timeout_ms + 999) / 1000 + 5 ))
while kill -0 "$open_pid" 2>/dev/null; do
    remember_children
    if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "macOS interaction LaunchServices command exceeded its deadline" >&2
        exit 124
    fi
    sleep 0.1
done
open_status=0
wait "$open_pid" || open_status=$?
open_pid=
[ "$open_status" -eq 0 ] || exit "$open_status"
# Bound transport output before the existing host result validator parses it.
[ "$(wc -c <"$work/result.json")" -le 4194304 ] || exit 65
[ -s "$work/result.json" ] || exit 65
cat "$work/result.json"
