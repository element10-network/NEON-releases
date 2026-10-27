#!/bin/sh
# First boot of a Neon SD image: installs the station with setup.sh, using the settings in
# neon.txt on the boot partition. Runs at every boot until it has succeeded once; the
# outcome is written to neon-status.txt next to neon.txt (readable from any computer).
set -u

BOOT=/boot/firmware
[ -d "$BOOT" ] || BOOT=/boot
CONF=$BOOT/neon.txt
STATUS=$BOOT/neon-status.txt
LOG=/var/log/neon-firstboot.log
DONE=/opt/neon/.image-setup-done

[ -f "$DONE" ] && exit 0
exec >>"$LOG" 2>&1
echo "== $(date -u '+%F %T') Neon first boot (image $(cat /opt/neon/image/commit 2>/dev/null))"

status() {
    { echo "Neon station setup: $1"; echo "Name: $(hostname), panel at http://$(hostname).local"
      echo "($(date -u '+%F %T') UTC; full log: $LOG)"; echo
      tail -n 30 "$LOG"; } > "$STATUS"
    sync
}

# KEY=VALUE lines; only these keys. A comment after the value (# ...) and spaces around it
# are ignored; a value with other characters stops the setup (rather than installing with
# the defaults, e.g. EU868 on a US station).
get() {
    v=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$CONF" 2>/dev/null | tail -n 1 | tr -d '\r' \
        | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    # Not grep: it sees no line in an empty value (a key left empty or not in the file, which
    # is allowed) and fails.
    case "$v" in
        *[!A-Za-z0-9_./:-]*)
            status "neon.txt: $1 has characters that are not allowed: fix it and restart"
            exit 1
            ;;
    esac
    printf '%s' "$v"
}
for k in NEON_REGION NEON_PRESET NEON_DEVICE NEON_REF NEON_HELIUM; do
    v=$(get "$k") || exit 1
    if [ -n "$v" ]; then export "$k=$v"; fi
done

# The name: NEON_NAME, else one set in Raspberry Pi Imager, else neon-XXXX (the last 4 hex
# digits of the MAC address). Set now, so every status line says where the panel will be.
rename() {
    hostnamectl set-hostname "$1" 2>/dev/null || echo "$1" > /etc/hostname
    hostname "$1" 2>/dev/null || true
    if grep -q '^127\.0\.1\.1' /etc/hosts; then
        sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$1/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$1" >> /etc/hosts
    fi
}
NAME=$(get NEON_NAME) || exit 1
NAME=$(printf '%s' "$NAME" | tr 'A-Z' 'a-z')
if [ -n "$NAME" ]; then
    if ! printf '%s' "$NAME" | grep -Eq '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'; then
        status "neon.txt: NEON_NAME must be lowercase letters, digits and hyphens (not at the start or end), at most 63: fix it and restart"
        exit 1
    fi
    [ "$NAME" = "$(hostname)" ] || rename "$NAME"
else
    case "$(hostname)" in
        raspberrypi|localhost|"")
            MAC=$(cat /sys/class/net/eth0/address /sys/class/net/end0/address /sys/class/net/wlan0/address 2>/dev/null | head -n 1 | tr -d ':\n')
            rename "neon-$(printf '%s' "${MAC:-0000}" | tail -c 4)"
            ;;
    esac
fi
status "starting"

# Wi-Fi from neon.txt: the name and password as written (spaces and symbols allowed). A raw
# WPA2 key (64 hex digits) goes the same way: NetworkManager takes it as the key itself.
raw() { sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$CONF" 2>/dev/null | tail -n 1 | tr -d '\r'; }
WIFI_SSID=$(raw NEON_WIFI_SSID)
WIFI_PASSWORD=$(raw NEON_WIFI_PASSWORD)
WIFI_COUNTRY=$(get NEON_WIFI_COUNTRY) || exit 1
# "pl" as PL: raspi-config and the kernel's list know the codes in capitals only.
WIFI_COUNTRY=$(printf '%s' "$WIFI_COUNTRY" | tr 'a-z' 'A-Z')
if [ -n "$WIFI_SSID" ] && command -v nmcli >/dev/null; then
    status "joining Wi-Fi $WIFI_SSID"
    if [ -n "$WIFI_COUNTRY" ] && command -v raspi-config >/dev/null; then
        raspi-config nonint do_wifi_country "$WIFI_COUNTRY" || true
    fi
    rfkill unblock wifi 2>/dev/null || true
    n=0
    while [ "$n" -lt 6 ]; do
        n=$((n + 1))
        nmcli device wifi rescan >/dev/null 2>&1
        sleep 5
        if [ -n "$WIFI_PASSWORD" ]; then
            nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASSWORD" && break
        else
            nmcli device wifi connect "$WIFI_SSID" && break
        fi
    done
fi

# SSH from neon.txt (owner, 2026-10-27): a user with a password hash (openssl passwd -6) and/or a
# public key, and SSH on, before the install, so it can be followed from another computer. The
# image has no user of its own. Empty: SSH stays as it is (off, unless Raspberry Pi Imager set it).
SSH_USER=$(get NEON_SSH_USER) || exit 1
SSH_HASH=$(raw NEON_SSH_HASH | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
SSH_KEY=$(raw NEON_SSH_KEY | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
if [ -n "$SSH_USER" ]; then
    if ! printf '%s' "$SSH_USER" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
        status "neon.txt: NEON_SSH_USER must be lowercase letters, digits, - and _ (at most 32): fix it and restart"
        exit 1
    fi
    case "$SSH_HASH" in ''|'$6$'*|'$5$'*|'$y$'*) ;; *)
        status "neon.txt: NEON_SSH_HASH must be a password hash from: openssl passwd -6 (it starts with \$6\$): fix it and restart"
        exit 1 ;;
    esac
    case "$SSH_KEY" in ''|ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-*\ *) ;; *)
        status "neon.txt: NEON_SSH_KEY must be a public key line (ssh-ed25519 AAAA...): fix it and restart"
        exit 1 ;;
    esac
    if [ -z "$SSH_HASH" ] && [ -z "$SSH_KEY" ]; then
        status "neon.txt: NEON_SSH_USER needs NEON_SSH_HASH or NEON_SSH_KEY (else nobody could log in): fix it and restart"
        exit 1
    fi
    id "$SSH_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo "$SSH_USER"
    usermod -aG sudo "$SSH_USER"
    [ -z "$SSH_HASH" ] || usermod -p "$SSH_HASH" "$SSH_USER"
    if [ -n "$SSH_KEY" ]; then
        home=$(getent passwd "$SSH_USER" | cut -d: -f6)
        install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "$home/.ssh"
        grep -qxF "$SSH_KEY" "$home/.ssh/authorized_keys" 2>/dev/null || printf '%s\n' "$SSH_KEY" >> "$home/.ssh/authorized_keys"
        chown "$SSH_USER:$SSH_USER" "$home/.ssh/authorized_keys"; chmod 600 "$home/.ssh/authorized_keys"
    fi
    # With a key only there is no password for sudo: it asks for none (like the image's old pi user).
    if [ -z "$SSH_HASH" ]; then
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$SSH_USER" > "/etc/sudoers.d/010-neon-$SSH_USER"
        chmod 440 "/etc/sudoers.d/010-neon-$SSH_USER"
    fi
    systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || true
    echo "SSH on for $SSH_USER"
fi

status "waiting for the network"
i=0
until getent hosts api.github.com >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 120 ]; then
        status "no network after 10 minutes (Ethernet cable? Wi-Fi in neon.txt or Raspberry Pi Imager, with the country?); tries again at the next boot"
        exit 1
    fi
    sleep 5
done

status "installing (the packet forwarder is built here: 5-20 minutes)"
tries=0
until sh /opt/neon/image/setup.sh; do
    tries=$((tries + 1))
    if [ "$tries" -ge 3 ]; then
        status "FAILED; tries again at the next boot"
        exit 1
    fi
    echo "setup failed; trying again in 60 s"
    sleep 60
done

touch "$DONE"
# NetworkManager keeps the Wi-Fi password (root only); not on the card's open partition.
sed -i 's/^\([[:space:]]*NEON_WIFI_PASSWORD[[:space:]]*=\).*/\1/' "$CONF"
sed -i 's/^\([[:space:]]*NEON_SSH_HASH[[:space:]]*=\).*/\1/' "$CONF"
IP=$(hostname -I 2>/dev/null | cut -d' ' -f1)
status "done. Open http://$(hostname).local (or http://${IP:-<the station address>}:8080) to finish the setup"
systemctl disable neon-firstboot.service 2>/dev/null || true
