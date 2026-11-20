#!/bin/sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
install_parent=${1:-/Applications}
identity=${2:--}
staging="$script_dir/.build/install"
built=$("$script_dir/build.sh" "$staging" "$identity")

mkdir -p "$install_parent"
destination="$install_parent/FesTermVMEvidenceInteraction.app"
rm -rf "$destination"
ditto "$built" "$destination"
/usr/bin/codesign --verify --deep --strict "$destination"
printf '%s\n' "$destination"
