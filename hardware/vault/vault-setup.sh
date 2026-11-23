#!/bin/sh
# Make a fresh Raspberry Pi OS Lite (64-bit) the NEON vault (owner 2026-11-15; vault.sh). Run once at
# its own screen and keyboard, logged in as `ne` (the user made with Raspberry Pi Imager, SSH left off):
#
#   curl -fsSL https://raw.githubusercontent.com/element10-network/NEON-releases/main/hardware/vault/vault-setup.sh | sudo sh
#
# It removes the SSH server and every other service that listens, turns on a firewall that drops all
# incoming connections and lets out only DNS, DHCP, time, ping, HTTP(S), the electrode's SSH port and any
# port an RPC address names, installs the newest signed release's neon-oracle, neon-token, neon-post.sh,
# the menu, the monitor and the (off) automatic updates (vault.sh update: each checked against the
# release key), and puts the monitor on the first screen and the menu on the others after logging in.
# The posting timer stays off until the settings and keys are imported and it is turned on in the menu.
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
# (/etc/neon, /var/lib/neon-post); only the menu moves to /opt/neon-vault (the old one is removed
# once the new one is installed).
mkdir -p /opt/neon-vault /opt/neon-post /var/lib/neon-post /etc/neon
chown ne:ne /var/lib/neon-post && chmod 700 /var/lib/neon-post

echo "==> The newest signed release"
# This script came from the release repository; the menu it installs checks every later file.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/vault.sh" "https://raw.githubusercontent.com/element10-network/NEON-releases/main/hardware/vault/vault.sh"
# The firewall first (review 2026-11-19): nothing comes in from here on, the update included.
echo "==> Firewall"
sh "$tmp/vault.sh" firewall
echo "==> Tools"
sh "$tmp/vault.sh" update
rm -rf /opt/neon-keybox

echo "==> The screens"
# (The update above put the monitor on the first console and the menu on the others: vault.sh screens.)
grep -q 'vault.sh menu' /home/ne/.bash_profile 2>/dev/null || sh /opt/neon-vault/vault.sh screens

echo
# (The rounded corners only when the console's font has them, as vault.sh's monitor.)
m="$tmp/fontmap"
if setfont -ou "$m" 2>/dev/null && grep -qi 'U+256d' "$m"; then
    printf '%s\n' '╭╮╭╮╭╮╭╮' '│││╯││││   vault' '││╰ ╰╯││'
else
    printf '%s\n' '┌┐┌┐┌┐┌┐' '│││┘││││   vault' '││└ └┘││'
fi
rm -f "$m"
echo
echo "Done. After the next restart (sudo reboot) the first screen (Alt+F1) shows the monitor; the menu is"
echo "on the next one (Alt+F2, log in as ne)."
echo "Next, in the menu:"
echo "  1. Import settings and keys...: from the old posting machine (SSH), or from a USB stick made on it"
echo "     (docs/HUB.md \"The vault\"); from a stick: Wipe the stick's copies, Unmount the stick"
echo "  (Automatic updates on / off in the menu: daily, newer signed releases only.)"
echo "  2. Status: the electrode answers, the admin key has SOL"
echo "  3. Turn the old machine's posting timer off, then here: Posting timer on"
