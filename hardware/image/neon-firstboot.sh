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
IP=$(hostname -I 2>/dev/null | cut -d' ' -f1)
status "done. Open http://$(hostname).local (or http://${IP:-<the station address>}:8080) to finish the setup"
systemctl disable neon-firstboot.service 2>/dev/null || true
