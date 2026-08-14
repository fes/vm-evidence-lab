#!/usr/bin/env sh
set -eu

[ "$#" -eq 4 ] || {
    echo "Usage: $0 <spool> <repository-root> <adapter-root> <relay-root>" >&2
    exit 2
}

mkdir -p "$HOME/Library/LaunchAgents" "$1/jobs" "$1/bundles" "$1/results" \
    "$1/logs" "$1/artifacts" "$2" "$3" "$4"
cp "$(dirname -- "$0")/common.sh" "$4/common.sh"
cp "$(dirname -- "$0")/unix.sh" "$4/unix.sh"
chmod 755 "$4/common.sh" "$4/unix.sh"
plist="$HOME/Library/LaunchAgents/com.fes.vm-evidence-relay.plist"

cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.fes.vm-evidence-relay</string>
  <key>ProgramArguments</key><array><string>$4/unix.sh</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>VM_EVIDENCE_SPOOL</key><string>$1</string>
    <key>VM_EVIDENCE_REPOSITORY_ROOT</key><string>$2</string>
    <key>VM_EVIDENCE_ADAPTER_ROOT</key><string>$3</string>
    <key>VM_EVIDENCE_PLATFORM</key><string>macos</string>
  </dict>
  <key>StartInterval</key><integer>10</integer>
</dict></plist>
EOF

launchctl bootout "gui/$(id -u)/com.fes.vm-evidence-relay" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
