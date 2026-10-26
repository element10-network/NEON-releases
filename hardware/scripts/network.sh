#!/bin/sh
# Local name and Wi-Fi setup for a Neon station. setup.sh runs it; it can also run alone
# (sudo sh network.sh) on a station installed before it existed.
#
# - The station answers as http://<hostname>.local (avahi, mDNS). A station still called
#   "raspberrypi" is renamed neon-XXXX (the last 4 hex digits of its MAC address).
# - Port 80 sends browsers to the panel on 8080 (neond --web-redirect).
# - With NetworkManager and Wi-Fi: the setup hotspot (neon-hotspot.sh) opens when the
#   station has had no network for 2 minutes; the panel there lists the networks nearby.
set -eu
PREFIX=/opt/neon
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

echo "==> Local name (mDNS)"
apt-get -o DPkg::Lock::Timeout=300 install -y -q avahi-daemon libnss-mdns iw
NAME=$(hostname)
case "$NAME" in
    raspberrypi|localhost|"")
        MAC=$(cat /sys/class/net/eth0/address /sys/class/net/end0/address /sys/class/net/wlan0/address 2>/dev/null | head -n 1 | tr -d ':\n')
        NEW="neon-$(printf '%s' "${MAC:-0000}" | tail -c 4)"
        hostnamectl set-hostname "$NEW" 2>/dev/null || echo "$NEW" > /etc/hostname
        if grep -q '^127\.0\.1\.1' /etc/hosts; then
            sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW/" /etc/hosts
        else
            printf '127.0.1.1\t%s\n' "$NEW" >> /etc/hosts
        fi
        NAME=$NEW
        echo "renamed the station $NAME"
        ;;
esac
mkdir -p /etc/avahi/services
cat > /etc/avahi/services/neon.service <<'XML'
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">Neon station %h</name>
  <service><type>_http._tcp</type><port>8080</port></service>
</service-group>
XML
systemctl enable -q avahi-daemon
systemctl restart avahi-daemon

echo "==> Port 80 to the panel"
if [ -f "$PREFIX/neond.env" ] && ! grep -q -- '--web-redirect' "$PREFIX/neond.env"; then
    sed -i 's/^\(NEOND_ARGS=.*\)$/\1 --web-redirect 0.0.0.0:80/' "$PREFIX/neond.env"
fi

if command -v nmcli >/dev/null && nmcli -t -f TYPE device 2>/dev/null | grep -qx wifi; then
    echo "==> Setup hotspot"
    install -m 755 "$HERE/neon-hotspot.sh" "$PREFIX/neon-hotspot.sh"
    install -m 644 "$HERE/../systemd/neon-hotspot.service" /etc/systemd/system/neon-hotspot.service
    # On the hotspot every name leads to the station, so phones open the panel by themselves.
    mkdir -p /etc/NetworkManager/dnsmasq-shared.d
    echo 'address=/#/10.42.0.1' > /etc/NetworkManager/dnsmasq-shared.d/neon-captive.conf
    systemctl daemon-reload
    systemctl enable -q neon-hotspot
    systemctl restart neon-hotspot
else
    echo "(no NetworkManager Wi-Fi: no setup hotspot)"
fi
echo "Panel: http://$NAME.local (and http://$NAME.local:8080)"
