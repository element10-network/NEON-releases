#!/bin/sh
# Make a fresh Raspberry Pi OS Lite (64-bit) the NEON vault (owner 2026-11-15; vault.sh). Run once at
# its own screen and keyboard, logged in as `ne` (the user made with Raspberry Pi Imager, SSH left off):
#
#   curl -fsSL https://raw.githubusercontent.com/element10-network/NEON-releases/main/hardware/vault/vault-setup.sh | sudo sh
#
# It removes the SSH server and every other service that listens, turns on a firewall that drops all
# incoming connections and lets out only DNS, time, HTTPS and the electrode's SSH port, installs the
# newest signed release's neon-oracle, neon-token, neon-post.sh and the menu (vault.sh update: each
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
# The SSH server: the vault is used at its own keyboard.
apt-get purge -y -q openssh-server >/dev/null 2>&1 || true
for u in ssh.service ssh.socket sshd.service avahi-daemon.service avahi-daemon.socket bluetooth.service \
    cups.service cups.socket rpcbind.service rpcbind.socket vncserver-x11-serviced.service rpi-connect.service; do
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    systemctl mask "$u" >/dev/null 2>&1 || true
done

echo "==> Folders"
# A box set up as the key box (before 2026-11-19): its settings, keys and epochs stay where they are
# (/etc/neon, /var/lib/neon-post); only the menu moves to /opt/neon-vault.
rm -rf /opt/neon-keybox
mkdir -p /opt/neon-vault /opt/neon-post /var/lib/neon-post /etc/neon
chown ne:ne /var/lib/neon-post && chmod 700 /var/lib/neon-post

echo "==> The newest signed release"
# This script came from the release repository; the menu it installs checks every later file.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/vault.sh" "https://raw.githubusercontent.com/element10-network/NEON-releases/main/hardware/vault/vault.sh"
sh "$tmp/vault.sh" update

echo "==> Firewall"
sh /opt/neon-vault/vault.sh firewall

echo "==> The menu on the screen"
profile=/home/ne/.bash_profile
touch "$profile"
# The key box's lines (before 2026-11-19) go.
sed -i "/The key box's menu/d; /keybox.sh menu/d" "$profile"
grep -q '^\[ -f ~/.bashrc \]' "$profile" || echo '[ -f ~/.bashrc ] && . ~/.bashrc' >> "$profile"
grep -q 'vault.sh menu' "$profile" || cat >> "$profile" <<'EOF'
# The vault's menu on its own screen (vault.sh); "Shell" in it leaves to this shell.
if [ "$(tty)" = /dev/tty1 ] && [ -z "${VAULT_SHELL:-}" ]; then /opt/neon-vault/vault.sh menu; fi
EOF
chown ne:ne "$profile"

echo
echo "Done. Next, in the menu (log out and in again, or run /opt/neon-vault/vault.sh menu):"
echo "  1. Import settings and keys from a USB stick (made on the old posting machine; docs/HUB.md \"The vault\")"
echo "  2. Wipe the stick's copies, Unmount the stick"
echo "  3. Status: the electrode answers, the admin key has SOL"
echo "  4. Turn the old machine's posting timer off, then here: Posting timer on"
