#!/usr/bin/env sh
set -eu

[ "$#" -eq 3 ] || {
    echo "usage: $0 <session.json> <command.json> <artifact-root>" >&2
    exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
driver="$script_dir/FesTermVMEvidenceInteraction.app/Contents/MacOS/FesTermVMEvidenceInteraction"
[ -x "$driver" ] || {
    echo "macOS interaction driver is not installed" >&2
    exit 69
}

exec "$driver" --session "$1" --artifact-root "$3" <"$2"
