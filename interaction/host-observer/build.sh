#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$HERE"

CONFIGURATION=${CONFIGURATION:-release}
ARCHES=${ARCHES:-"$(uname -m)"}
case "$ARCHES" in
  arm64) SWIFT_ARCH=arm64 ;;
  x86_64) SWIFT_ARCH=x86_64 ;;
  universal) SWIFT_ARCH="arm64 x86_64" ;;
  *) echo "ARCHES must be arm64, x86_64, or universal" >&2; exit 2 ;;
esac

ARCH_ARGS=
for arch in $SWIFT_ARCH; do
  ARCH_ARGS="$ARCH_ARGS --arch $arch"
done

# Intentional shell splitting: swift build expects one --arch pair per architecture.
# shellcheck disable=SC2086
swift build -c "$CONFIGURATION" $ARCH_ARGS
# shellcheck disable=SC2086
BINARY_DIR=$(swift build -c "$CONFIGURATION" $ARCH_ARGS --show-bin-path)

BUNDLE="$HERE/dist/VM Evidence Host Observer.app"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BINARY_DIR/vm-host-observer" "$BUNDLE/Contents/MacOS/vm-host-observer"
cp "$HERE/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
plutil -lint "$BUNDLE/Contents/Info.plist" >/dev/null
codesign --force --sign "${CODESIGN_IDENTITY:--}" \
  --identifier org.vm-evidence-lab.host-observer "$BUNDLE"
codesign --verify --strict --verbose=2 "$BUNDLE"
echo "$BUNDLE"
