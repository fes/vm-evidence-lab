#!/usr/bin/env sh
set -eu

[ "$#" -eq 4 ] || {
    echo "Usage: $0 <spool> <repository-root> <adapter-root> <relay-root>" >&2
    exit 2
}

service_root=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user
mkdir -p "$service_root" "$1/jobs" "$1/bundles" "$1/results" "$1/logs" \
    "$1/artifacts" "$2" "$3" "$4"
cp "$(dirname -- "$0")/common.sh" "$4/common.sh"
cp "$(dirname -- "$0")/unix.sh" "$4/unix.sh"
chmod 755 "$4/common.sh" "$4/unix.sh"

systemctl --user disable --now festerm-vm-evidence-relay.path 2>/dev/null || true
systemctl --user stop festerm-vm-evidence-relay.service 2>/dev/null || true
rm -f "$service_root/festerm-vm-evidence-relay.path" \
    "$service_root/festerm-vm-evidence-relay.service"

cat >"$service_root/vm-evidence-relay.service" <<EOF
[Unit]
Description=VM evidence graphical-session relay

[Service]
Type=oneshot
Environment=VM_EVIDENCE_SPOOL=$1
Environment=VM_EVIDENCE_REPOSITORY_ROOT=$2
Environment=VM_EVIDENCE_ADAPTER_ROOT=$3
Environment=VM_EVIDENCE_PLATFORM=linux
ExecStart=$4/unix.sh
EOF

cat >"$service_root/vm-evidence-relay.path" <<EOF
[Unit]
Description=Watch for VM evidence jobs

[Path]
PathChanged=$1/jobs

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now vm-evidence-relay.path
