#!/bin/sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
installed=/Applications/FesTermVMEvidenceInteraction.app/Contents/MacOS/FesTermVMEvidenceInteraction
local="$script_dir/.build/FesTermVMEvidenceInteraction.app/Contents/MacOS/FesTermVMEvidenceInteraction"
if [ -x "$installed" ]; then
    exec "$installed" "$@"
fi
if [ -x "$local" ]; then
    exec "$local" "$@"
fi
echo "Build with $script_dir/build.sh or install with $script_dir/install.sh first." >&2
exit 69
