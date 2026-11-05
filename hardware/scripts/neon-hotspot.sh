#!/bin/sh
# Neon setup hotspot (neon-hotspot.service). When the station has had no network (Ethernet
# or Wi-Fi) for 2 minutes, it opens its own Wi-Fi network: "Neon Setup XXXX" before the
# station is set up, "Neon XXXX" after (the same XXXX, from its name); a phone or
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

# The Wi-Fi device (it can show up a little after NetworkManager at boot: 2 minutes of looks).
n=0
while :; do
    DEV=$(nmcli -t -f DEVICE,TYPE device 2>/dev/null | awk -F: '$2 == "wifi" { print $1; exit }')
    [ -n "$DEV" ] && break
    n=$((n + 1))
    [ "$n" -ge 12 ] && { echo "no Wi-Fi device; looking again in 10 minutes"; sleep 600; exit 0; }
    sleep 10
done
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
# The hotspot's name, read each time it opens (the setup may have happened since): "Neon Setup XXXX"
# before the setup, "Neon XXXX" after it (owner 2026-11-05; XXXX: the first 4 hex digits, upper case,
# of the hostname's SHA-256, the same in both, so one atom's two networks are told apart from
# another's; neond's wifi::hotspot_name makes the same for the panel).
ssid() {
    id=$(hostname | tr -d '\n' | sha256sum | cut -c1-4 | tr 'a-f' 'A-F')
    if set_up; then
        printf 'Neon %s' "$id"
    else
        printf 'Neon Setup %s' "$id"
    fi
}
# The panel joining a network (it takes the hotspot down first): left alone meanwhile.
JOINING=/run/neon/joining

online() {
    nmcli -t -f TYPE,STATE,CONNECTION device 2>/dev/null | grep -v ":$CON\$" \
        | grep -Eq '^(ethernet|wifi):connected:'
}
hotspot_on() { nmcli -t -f NAME connection show --active 2>/dev/null | grep -qx "$CON"; }
# A Wi-Fi it knows besides its own hotspot (one it could go back to).
knows_wifi() { nmcli -t -f TYPE,NAME connection show 2>/dev/null | grep '^802-11-wireless:' | grep -vqx "802-11-wireless:$CON"; }
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
        echo "setup hotspot did not start (Wi-Fi country set? raspi-config, Localisation); again in 10 minutes"
        return 1
    fi
}

offline_since=$(date +%s)
hot_since=0
# Already up (this script restarted: an update or a rename, neond 2026-11-05): counted from now, so a
# phone on it is not dropped for the 30-minute step aside.
hotspot_on && hot_since=$(date +%s)
# Up under another name (the atom took its board's name, or an older script named it): opened again
# under the right one, else the panel shows a name that is not on the air.
# (Read once; an empty answer, nmcli busy, is no reason to drop a phone.) Down first: the radio
# cannot scan for the panel's list while it is the access point.
if hotspot_on; then
    cur=$(nmcli -g 802-11-wireless.ssid connection show "$CON" 2>/dev/null)
    if [ -n "$cur" ] && [ "$cur" != "$(ssid)" ]; then
        nmcli connection down "$CON" >/dev/null 2>&1
        sleep 2
        start || offline_since=$(($(date +%s) + 480))
    fi
fi
was_on=no
while sleep 30; do
    now=$(date +%s)
    # Brought back up by someone else (the panel after a failed join): counted from now.
    if hotspot_on; then [ "$was_on" = yes ] || hot_since=$now; was_on=yes; else was_on=no; fi
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
        # (The panel brings the hotspot back after a failed join: counted from then.)
        was_on=no
        continue
    fi
    if hotspot_on; then
        # Every 10 minutes with nobody on it, and every 30 minutes anyway (a phone that
        # rejoins by itself must not keep the station off a network that came back), the
        # hotspot steps aside for a minute: only with a network it could come back to (a saved
        # Wi-Fi; a cable is seen anyway), else it would only drop a phone in the middle of the setup.
        if knows_wifi && { { [ $((now - hot_since)) -ge 600 ] && nobody_on; } || [ $((now - hot_since)) -ge 1800 ]; }; then
            nobody_on && had=no || had=yes
            nmcli connection down "$CON" >/dev/null 2>&1
            sleep 60
            if online; then
                echo "a known network came back: setup hotspot off"
                offline_since=$(date +%s)
                continue
            fi
            # A phone was on: back under the same name (it rejoins by itself), not a new one.
            if [ "$had" = yes ] && nmcli connection up "$CON" >/dev/null 2>&1; then
                hot_since=$(date +%s); was_on=yes
            elif start; then hot_since=$(date +%s); was_on=yes; else offline_since=$(($(date +%s) + 480)); fi
        fi
        continue
    fi
    if [ $((now - offline_since)) -ge 120 ]; then
        # Not started (no country, AP refused): again in 10 minutes, not every 30 s.
        if start; then hot_since=$now; was_on=yes; else offline_since=$((now + 480)); fi
    fi
done
