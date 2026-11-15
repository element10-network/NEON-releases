#!/bin/sh
# Make a fresh Raspberry Pi OS Lite (64-bit) the NEON key box (owner 2026-11-15; keybox.sh). Run once at
# its own screen and keyboard, logged in as `ne` (the user made with Raspberry Pi Imager, SSH left off):
#
#   curl -fsSL https://raw.githubusercontent.com/element10-network/NEON-releases/main/hardware/keybox/keybox-setup.sh | sudo sh
#
# It removes the SSH server and every other service that listens, turns on a firewall that drops all
# incoming connections and lets out only DNS, time, HTTPS and the electrode's SSH port, installs the
# newest signed release's neon-oracle, neon-token, neon-post.sh and the menu (keybox.sh update: each
# checked against the release key), and starts the menu on the screen after logging in. The posting
# timer stays off until the settings and keys are imported and it is turned on in the menu.
set -eu
die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run with sudo"
id ne >/dev/null 2>&1 || die "no user ne: make it with Raspberry Pi Imager (user name ne)"

echo "==> Packages"
apt-get update -q
apt-get install -y -q git jq curl nftables whiptail openssh-client ca-certificates python3 nano

echo "==> Nothing listening"
# The SSH server: the key box is used at its own keyboard.
apt-get purge -y -q openssh-server >/dev/null 2>&1 || true
for u in ssh.service ssh.socket sshd.service avahi-daemon.service avahi-daemon.socket bluetooth.service \
    cups.service cups.socket rpcbind.service rpcbind.socket vncserver-x11-serviced.service rpi-connect.service; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    systemctl mask "$u" >/dev/null 2>&1 || true
done

echo "==> Folders"
mkdir -p /opt/neon-keybox /opt/neon-post /var/lib/neon-post /etc/neon
chown ne:ne /var/lib/neon-post && chmod 700 /var/lib/neon-post

echo "==> The newest signed release"
# This script came from the release repository; the menu it installs checks every later file.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/keybox.sh" "https://raw.githubusercontent.com/element10-network/NEON-releases/main/hardware/keybox/keybox.sh"
sh "$tmp/keybox.sh" update

echo "==> Firewall"
sh /opt/neon-keybox/keybox.sh firewall

echo "==> The menu on the screen"
profile=/home/ne/.bash_profile
touch "$profile"
grep -q 'keybox.sh menu' "$profile" || cat >> "$profile" <<'EOF'
# The key box's menu on its own screen (keybox.sh); "Shell" in it leaves to this shell.
[ -f ~/.bashrc ] && . ~/.bashrc
if [ "$(tty)" = /dev/tty1 ] && [ -z "${KEYBOX_SHELL:-}" ]; then /opt/neon-keybox/keybox.sh menu; fi
EOF
chown ne:ne "$profile"

echo
echo "Done. Next, in the menu (log out and in again, or run /opt/neon-keybox/keybox.sh menu):"
echo "  1. Import settings and keys from a USB stick (made on the old posting machine; docs/HUB.md \"The key box\")"
echo "  2. Wipe the stick's copies, Unmount the stick"
echo "  3. Status: the electrode answers, the admin key has SOL"
echo "  4. Turn the old machine's posting timer off, then here: Posting timer on"
