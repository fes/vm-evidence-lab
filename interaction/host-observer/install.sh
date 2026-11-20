#!/bin/sh
set -eu

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTALL_PREFIX=${1:-"$HOME"}
APP_DIR="$INSTALL_PREFIX/Applications"
BIN_DIR="$INSTALL_PREFIX/.local/bin"

"$HERE/build.sh" >/dev/null
BUNDLE="$HERE/dist/VM Evidence Host Observer.app"

mkdir -p "$APP_DIR" "$BIN_DIR"
rm -rf "$APP_DIR/VM Evidence Host Observer.app"
cp -R "$BUNDLE" "$APP_DIR/VM Evidence Host Observer.app"

cat >"$BIN_DIR/vm-host-observer" <<EOF
#!/bin/sh
set -eu
HERE=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
PREFIX=\$(CDPATH= cd -- "\$HERE/../.." && pwd)
exec "\$PREFIX/Applications/VM Evidence Host Observer.app/Contents/MacOS/vm-host-observer" "\$@"
EOF
chmod 755 "$BIN_DIR/vm-host-observer"
printf 'Installed %s\nWrapper: %s\n' \
  "$APP_DIR/VM Evidence Host Observer.app" "$BIN_DIR/vm-host-observer"
