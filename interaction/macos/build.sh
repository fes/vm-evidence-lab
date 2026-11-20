#!/bin/sh
set -eu

script_dir=$(unset CDPATH; cd -- "$(dirname -- "$0")" && pwd)
output_dir=${1:-"$script_dir/.build"}
identity=${2:--}
bundle="$output_dir/FesTermVMEvidenceInteraction.app"

mkdir -p "$bundle/Contents/MacOS"
cp "$script_dir/Info.plist" "$bundle/Contents/Info.plist"
xcrun swiftc -swift-version 5 -O \
  -framework Foundation -framework AppKit -framework ApplicationServices \
  -framework CoreGraphics -framework CryptoKit \
  "$script_dir/Models.swift" "$script_dir/Driver.swift" "$script_dir/main.swift" \
  -o "$bundle/Contents/MacOS/FesTermVMEvidenceInteraction"
chmod 755 "$bundle/Contents/MacOS/FesTermVMEvidenceInteraction"
/usr/bin/codesign --force --deep --sign "$identity" "$bundle"

printf '%s\n' "$bundle"
