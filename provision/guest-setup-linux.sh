#!/usr/bin/env bash
# Configure a freshly autoinstalled Ubuntu 24.04 ARM64 Xorg guest as an evidence
# baseline. Run as root inside the guest (sudo), after provision/make_seeds.py
# installed the OS. Idempotent. See docs/PROVISIONING.md.
#
# Usage: sudo ./guest-setup-linux.sh <path-to-vm-evidence-lab-relay-dir>
#
# Parallels Tools: if the Tools ISO is attached as a CD-ROM (and the guest was
# rebooted so /dev/sr0 exists) the script installs it; otherwise it only warns.
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 2; }
[ "$#" -eq 1 ] && [ -f "$1/install-linux.sh" ] || { echo "usage: $0 <relay-dir>" >&2; exit 2; }
relay_src=$(cd "$1" && pwd)

user=${EVIDENCE_USER:-evidence}
uid=$(id -u "$user")
home=$(getent passwd "$user" | cut -d: -f6)
swap_gib=${EVIDENCE_SWAP_GIB:-8}
export DEBIAN_FRONTEND=noninteractive

as_user() {
    sudo -u "$user" env HOME="$home" XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
}

mem_mib=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
if [ "$mem_mib" -lt 7500 ]; then
    echo "warning: ${mem_mib} MiB RAM; full workspace builds and cargo bench need >= 8192 MiB" >&2
fi

# Packages. The second group is required by workspace crates (libudev, fonts,
# audio, TLS, X11 extensions); omitting it fails `cargo build --workspace`.
apt-get update
apt-get install -y \
    build-essential pkg-config libxkbcommon-dev libxkbcommon-x11-dev \
    libwayland-dev libx11-dev libxcb1-dev libvulkan-dev mesa-vulkan-drivers \
    xvfb vttest less vim-nox neovim tmux screen htop gh git jq xdotool wmctrl \
    imagemagick x11-utils scrot python3 curl openssh-server dkms \
    linux-headers-generic \
    libudev-dev libfontconfig1-dev libfreetype-dev libxcursor-dev libxi-dev \
    libxrandr-dev libasound2-dev libssl-dev libxcb-xfixes0-dev \
    libxcb-shape0-dev libxcb-render0-dev

# Swap: workspace linking and `cargo bench` OOM-kill ld on 6 GiB guests.
if ! grep -q '^/swapfile ' /etc/fstab; then
    fallocate -l "${swap_gib}G" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    echo '/swapfile none swap sw 0 0' >>/etc/fstab
fi
swapon -a

# No unattended changes or upgrade prompts inside a qualified baseline.
systemctl disable --now unattended-upgrades apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
sed -i 's/^Prompt=.*/Prompt=never/' /etc/update-manager/release-upgrades

# Rust (stable) for the evidence user.
if [ ! -x "$home/.cargo/bin/rustc" ]; then
    as_user bash -c 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal -c clippy,rustfmt'
fi

# Parallels Tools, when the Tools ISO is attached.
if [ ! -d /usr/lib/parallels-tools ]; then
    if [ -b /dev/sr0 ]; then
        mkdir -p /mnt/prl
        mount -o ro /dev/sr0 /mnt/prl
        if [ -x /mnt/prl/install ]; then
            /mnt/prl/install --install-unattended-with-deps || echo "warning: Parallels Tools installer failed" >&2
        else
            echo "warning: /dev/sr0 is not the Parallels Tools ISO" >&2
        fi
        umount /mnt/prl || true
    else
        echo "warning: Parallels Tools not installed; attach the Tools ISO, reboot, rerun" >&2
    fi
fi

# Quiet the desktop: no lock, idle, sleep, banners or update popups.
loginctl enable-linger "$user"
if [ -S "/run/user/$uid/bus" ]; then
    as_user gsettings set org.gnome.desktop.session idle-delay 0
    as_user gsettings set org.gnome.desktop.screensaver idle-activation-enabled false
    as_user gsettings set org.gnome.desktop.screensaver lock-enabled false
    as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing
    as_user gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type nothing
    as_user gsettings set org.gnome.desktop.notifications show-banners false
    as_user gsettings set com.ubuntu.update-notifier no-show-notifications true
else
    echo "warning: no desktop session bus for $user; GNOME settings not applied (autologin must be active)" >&2
fi
mkdir -p "$home/.config"
as_user touch "$home/.config/gnome-initial-setup-done"

# Graphical-session relay and its private working directories.
install -d -o "$user" -g "$user" "$home/.local/share/vm-evidence-lab-install"
cp -r "$relay_src" "$home/.local/share/vm-evidence-lab-install/relay"
chown -R "$user:$user" "$home/.local/share/vm-evidence-lab-install"
as_user sh "$home/.local/share/vm-evidence-lab-install/relay/install-linux.sh" \
    "$home/vm-evidence-spool" "$home/vm-evidence-sources" \
    "$home/.local/share/vm-evidence-adapters" "$home/.local/share/vm-evidence-lab"
rm -rf "$home/.local/share/vm-evidence-lab-install"

# Verify, so a bad baseline fails here rather than in a qualification run.
for tool in cargo gcc pkg-config xdotool tmux screen jq git; do
    command -v "$tool" >/dev/null || [ -x "$home/.cargo/bin/$tool" ] || { echo "missing $tool" >&2; exit 1; }
done
pkg-config --exists libudev fontconfig freetype2 xkbcommon alsa openssl
as_user systemctl --user is-enabled vm-evidence-relay.path >/dev/null
echo "guest-setup-linux: complete"
