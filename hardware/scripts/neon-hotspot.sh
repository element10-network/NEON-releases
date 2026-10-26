#!/bin/sh
# Neon setup hotspot (neon-hotspot.service). When the station has had no network (Ethernet
# or Wi-Fi) for 2 minutes, it opens its own Wi-Fi network: "Neon-Setup-<name>" before the
# station is set up, "Neon-<name>" after (<name>: the hostname without "neon-"); a phone or
# laptop that joins it is shown the panel (every name resolves to the station, port 80
# redirects to the panel), where Settings -> Wi-Fi joins a network. The networks seen just
# before are kept in /run/neon/wifi-scan.txt for the panel (the radio cannot scan as an
# access point). Every 10 minutes with nobody on it (30 minutes in any case), the hotspot
# steps aside for a minute so known networks can come back (a router that was restarting).
#
# Optional /opt/neon/hotspot.conf: HOTSPOT_PASSWORD=8 to 63 characters (default: open).
CON=neon-setup
SCAN=/run/neon/wifi-scan.txt
HOTSPOT_PASSWORD=""
[ -f /opt/neon/hotspot.conf ] && . /opt/neon/hotspot.conf

DEV=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" { print $1; exit }')
[ -n "$DEV" ] || { echo "no Wi-Fi device; looking again in 10 minutes"; sleep 600; exit 0; }
# Set up: the panel's setup page (or any settings save) wrote the settings file, or the
# panel password is given on the command line (neond's own test: no setup page then).
ENV=/opt/neon/neond.env
set_up() {
    args=$(sed -n 's/^NEOND_ARGS=//p' "$ENV" 2>/dev/null | tail -n 1)
    case " $args " in
        *" --web-password"*) return 0;;
        *" --config="*) conf=$(printf ' %s ' "$args" | sed -n 's/.* --config=\([^ ]*\) .*/\1/p');;
        *" --config "*) conf=$(printf ' %s ' "$args" | sed -n 's/.* --config \([^ ]*\) .*/\1/p');;
        *) conf="";;
    esac
    [ -f "${conf:-/opt/neon/neond.toml}" ]
}
# The hotspot's name, read each time it opens (the setup may have happened since). Letters,
# digits and hyphens only, and at most 32 bytes (an SSID's limit: a longer one would stop
# the hotspot from starting).
ssid() {
    name=$(hostname | sed 's/^neon-//' | tr -cd 'A-Za-z0-9-')
    if set_up && [ -n "$name" ]; then
        printf 'Neon-%s' "$name" | cut -c1-32
    else
        printf 'Neon-Setup-%s' "$name" | cut -c1-32
    fi
}
# The panel joining a network (it takes the hotspot down first): left alone meanwhile.
JOINING=/run/neon/joining

online() {
    nmcli -t -f TYPE,STATE,CONNECTION device 2>/dev/null | grep -v ":$CON\$" \
        | grep -Eq '^(ethernet|wifi):connected:'
}
hotspot_on() { nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$CON"; }
nobody_on() { [ -z "$(iw dev "$DEV" station dump 2>/dev/null)" ]; }

start() {
    mkdir -p /run/neon
    nmcli device wifi rescan ifname "$DEV" >/dev/null 2>&1
    sleep 5
    nmcli -t -f SSID,SIGNAL,SECURITY device wifi list ifname "$DEV" > "$SCAN.tmp" 2>/dev/null \
        && mv "$SCAN.tmp" "$SCAN"
    nmcli connection delete "$CON" >/dev/null 2>&1
    SSID=$(ssid)
    set -- connection add type wifi ifname "$DEV" con-name "$CON" autoconnect no ssid "$SSID" \
        802-11-wireless.mode ap 802-11-wireless.band bg ipv4.method shared ipv6.method ignore
    if [ -n "$HOTSPOT_PASSWORD" ]; then
        set -- "$@" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$HOTSPOT_PASSWORD"
    fi
    if nmcli "$@" >/dev/null && nmcli connection up "$CON" >/dev/null; then
        echo "no network: setup hotspot $SSID on"
    else
        echo "setup hotspot did not start (Wi-Fi country set? raspi-config, Localisation)"
    fi
}

offline_since=$(date +%s)
hot_since=0
while sleep 30; do
    now=$(date +%s)
    if online; then
        # Ethernet plugged in while the hotspot is on: it is not needed any more.
        if hotspot_on; then
            nmcli connection down "$CON" >/dev/null 2>&1
            echo "network back: setup hotspot off"
        fi
        offline_since=$now
        continue
    fi
    if [ -f "$JOINING" ] && [ $((now - $(stat -c %Y "$JOINING" 2>/dev/null || echo 0))) -lt 120 ]; then
        offline_since=$now
        continue
    fi
    if hotspot_on; then
        # Every 10 minutes with nobody on it, and every 30 minutes anyway (a phone that
        # rejoins by itself must not keep the station off a network that came back), the
        # hotspot steps aside for a minute.
        if { [ $((now - hot_since)) -ge 600 ] && nobody_on; } || [ $((now - hot_since)) -ge 1800 ]; then
            nmcli connection down "$CON" >/dev/null 2>&1
            sleep 60
            if online; then
                echo "a known network came back: setup hotspot off"
                offline_since=$(date +%s)
                continue
            fi
            start
            hot_since=$(date +%s)
        fi
        continue
    fi
    if [ $((now - offline_since)) -ge 120 ]; then
        start
        hot_since=$now
    fi
done
