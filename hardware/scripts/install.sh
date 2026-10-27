#!/bin/sh
# Build and install the Neon-patched Semtech packet forwarder on a hotspot.
#
# Run on the hotspot itself, as root, from a checkout of this repository:
#   sudo hardware/scripts/install.sh <device> <region> [auto|sx1302|sx1301] [preset]
#
#   device  rak-v2 | nebra-rockpi4   (see hardware/devices/)
#   region  EU868 | US915            (see hardware/configs/)
#   preset  the local mesh's Meshtastic modem preset (default LongFast). EU868 takes
#           ShortFast, ShortSlow, MediumFast, MediumSlow or LongFast: all are 250 kHz wide
#           and share 869.525 MHz there. US915 takes LongFast only for now, because each
#           preset has its own frequency there.
#
# With "auto" (the default), the SX1302 HAL is built first and its chip_id
# tool probes the concentrator. If that fails, the SX1301 HAL is built instead.
#
# Installs to /opt/neon (override with NEON_PREFIX) and writes the systemd
# units neon-forwarder.service and neond.service without enabling them.

set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

# put FILE DIR: copy a program into DIR, replacing (not overwriting) the old one, which
# works while the old one is running.
put() {
    cp "$1" "$2/$(basename "$1").new" && mv -f "$2/$(basename "$1").new" "$2/$(basename "$1")"
}

[ $# -ge 2 ] || die "usage: $0 <rak-v2|nebra-rockpi4> <EU868|US915> [auto|sx1302|sx1301] [preset]"
DEVICE=$1
REGION=$2
CHIP=${3:-auto}
PRESET=${4:-LongFast}

HW=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${NEON_PREFIX:-/opt/neon}
SRC=$PREFIX/src
ENV_FILE=$HW/devices/$DEVICE.env

[ -f "$ENV_FILE" ] || die "unknown device '$DEVICE' (no $ENV_FILE)"
case "$REGION" in EU868|US915) ;; *) die "unknown region '$REGION'" ;; esac
case "$CHIP" in auto|sx1302|sx1301) ;; *) die "unknown chip '$CHIP'" ;; esac
# Spreading factor of the LoRa service channel for each supported preset (all BW 250 kHz).
case "$PRESET" in
    ShortFast) SF=7 ;;
    ShortSlow) SF=8 ;;
    MediumFast) SF=9 ;;
    MediumSlow) SF=10 ;;
    LongFast) SF=11 ;;
    *) die "unsupported preset '$PRESET' (ShortFast, ShortSlow, MediumFast, MediumSlow or LongFast)" ;;
esac
[ "$REGION" = EU868 ] || [ "$PRESET" = LongFast ] || die "only LongFast is supported for $REGION"
[ "$(id -u)" -eq 0 ] || die "run as root"
. "$ENV_FILE"
# A device whose chip is known (NEON_CHIP in its profile) never falls back to the other HAL:
# a chip that does not answer is a fault to fix (seating, reset line), not another chip.
if [ "$CHIP" = auto ] && [ -n "${NEON_CHIP:-}" ]; then
    CHIP=$NEON_CHIP
fi
if [ ! -e "$NEON_SPI" ]; then
    FIRST=$(ls /dev/spidev* 2>/dev/null | head -n 1)
    [ -n "$FIRST" ] || die "no SPI device found: enable SPI (see hardware/README.md)"
    echo "NOTE: $NEON_SPI does not exist. SPI devices present: $(ls /dev/spidev* | tr '\n' ' ')"
    echo "NOTE: starting with $FIRST"
    NEON_SPI=$FIRST
fi

if command -v apt-get >/dev/null; then
    apt-get -o DPkg::Lock::Timeout=300 install -y git build-essential
fi
mkdir -p "$SRC"

# fetch <repo> <tag> <patch>: clone a Semtech repository at a release tag and apply our patch.
# When the patch file changes, the source is reset to the tag and re-patched, then cleaned.
# fetch NAME TAG PATCH COMMIT: the tag's commit is checked (a tag can be moved; this runs as root).
fetch() {
    if [ ! -d "$SRC/$1" ]; then
        git clone --depth 1 --branch "$2" "https://github.com/Lora-net/$1.git" "$SRC/$1"
    fi
    have_commit=$(git -C "$SRC/$1" rev-parse HEAD)
    [ "$have_commit" = "$4" ] || die "$1 $2 is commit $have_commit, expected $4"
    want=$(sha256sum "$HW/patches/$3" | cut -d' ' -f1)
    have=$(cat "$SRC/$1/.neon-patch" 2>/dev/null || true)
    if [ "$want" != "$have" ]; then
        echo "Applying $3 to $1"
        git -C "$SRC/$1" checkout -- .
        git -C "$SRC/$1" apply "$HW/patches/$3"
        echo "$want" > "$SRC/$1/.neon-patch"
        make -C "$SRC/$1" clean >/dev/null 2>&1 || true
    fi
}

# stage <dir>: copy the reset script and device profile next to a forwarder.
stage() {
    mkdir -p "$1"
    cp "$HW/scripts/reset_lgw.sh" "$1/reset_lgw.sh"
    cp "$HW/scripts/run_forwarder.sh" "$1/run.sh"
    cp "$ENV_FILE" "$1/device.env"
}

# set_spi_speed <file>: apply NEON_SPI_HZ (if set) to a HAL's SPI_SPEED define. Returns 0 if it changed.
set_spi_speed() {
    [ -n "${NEON_SPI_HZ:-}" ] || return 1
    grep -q "^#define SPI_SPEED *$NEON_SPI_HZ\$" "$1" && return 1
    sed -i "s|^#define SPI_SPEED .*|#define SPI_SPEED       $NEON_SPI_HZ|" "$1"
    echo "SPI clock set to $NEON_SPI_HZ Hz in $1"
}

build_sx1302() {
    fetch sx1302_hal V2.1.0 sx1302_hal-v2.1.0-mesh-syncword.patch 4b42025d1751e04632c0b04160e0d29dbbb222a5
    if set_spi_speed "$SRC/sx1302_hal/libloragw/inc/loragw_spi.h"; then
        make -C "$SRC/sx1302_hal" clean
    fi
    make -C "$SRC/sx1302_hal"
    DIR=$PREFIX/sx1302
    stage "$DIR"
    put "$SRC/sx1302_hal/packet_forwarder/lora_pkt_fwd" "$DIR"
    put "$SRC/sx1302_hal/util_chip_id/chip_id" "$DIR"
}

# probe_sx1302 <spidev>: succeeds and prints the concentrator EUI if an SX1302/SX1303 answers.
# chip_id's output is kept in $PREFIX/sx1302/chip_id.log so failures can be diagnosed.
probe_sx1302() {
    log=$PREFIX/sx1302/chip_id.log
    (cd "$PREFIX/sx1302" && ./chip_id -d "$1") > "$log" 2>&1 || return 1
    sed -n 's/.*concentrator EUI: 0x\([0-9a-fA-F]*\).*/\1/p' "$log" | head -n 1
}

# find_sx1302: probe NEON_SPI, then every other SPI device; sets NEON_SPI and EUI on success.
find_sx1302() {
    for dev in "$NEON_SPI" /dev/spidev*; do
        [ -e "$dev" ] || continue
        if EUI=$(probe_sx1302 "$dev") && [ -n "$EUI" ]; then
            if [ "$dev" != "$NEON_SPI" ]; then
                echo "NOTE: the SX1302 answered on $dev, not $NEON_SPI. Update NEON_SPI in $ENV_FILE."
                NEON_SPI=$dev
            fi
            return 0
        fi
    done
    return 1
}

build_sx1301() {
    fetch lora_gateway v5.0.1 lora_gateway-v5.0.1-mesh-syncword.patch a955619271b5d0a46d32e08150acfbc1eed183b7
    fetch packet_forwarder v4.0.1 packet_forwarder-v4.0.1-mesh-syncword.patch d0226eae6e7b6bbaec6117d0d2372bf17819c438
    # The SX1301 HAL takes its SPI device path at compile time.
    sed -i "s|^#define SPI_DEV_PATH .*|#define SPI_DEV_PATH    \"$NEON_SPI\"|" \
        "$SRC/lora_gateway/libloragw/src/loragw_spi.native.c"
    if set_spi_speed "$SRC/lora_gateway/libloragw/src/loragw_spi.native.c"; then
        make -C "$SRC/lora_gateway" clean
        make -C "$SRC/packet_forwarder" clean
    fi
    make -C "$SRC/lora_gateway"
    make -C "$SRC/packet_forwarder"
    DIR=$PREFIX/sx1301
    stage "$DIR"
    put "$SRC/packet_forwarder/lora_pkt_fwd/lora_pkt_fwd" "$DIR"
}

# mac_eui: gateway ID derived from the first Ethernet MAC (xx:xx:xx:FF:FE:xx:xx:xx).
mac_eui() {
    for nic in /sys/class/net/eth* /sys/class/net/end* /sys/class/net/wlan*; do
        [ -f "$nic/address" ] || continue
        mac=$(tr -d ':\n' < "$nic/address")
        echo "$(echo "$mac" | cut -c1-6)fffe$(echo "$mac" | cut -c7-12)"
        return
    done
    echo AA555A0000000000
}

EUI=""
if [ "$CHIP" != sx1301 ]; then
    build_sx1302
    if find_sx1302; then
        CHIP=sx1302
        echo "SX1302/SX1303 concentrator found on $NEON_SPI, EUI $EUI"
    else
        echo "chip_id output (last attempt, $PREFIX/sx1302/chip_id.log):" >&2
        tail -n 15 "$PREFIX/sx1302/chip_id.log" >&2
        echo "Run hardware/scripts/probe_concentrator.py to identify the chip, SPI device and reset GPIO." >&2
    fi
    if [ "$CHIP" = sx1302 ] && [ -z "$EUI" ]; then
        die "no SX1302 answered on any SPI device: is the radio board pressed fully onto the 40-pin header? (chip_id's output is above)"
    elif [ "$CHIP" = auto ]; then
        echo "No SX1302 answered on any SPI device; building the SX1301 HAL for $NEON_SPI"
        CHIP=sx1301
    fi
fi
if [ "$CHIP" = sx1301 ]; then
    build_sx1301
    EUI=$(mac_eui)
fi

DIR=$PREFIX/$CHIP
sed -i "s|^NEON_SPI=.*|NEON_SPI=$NEON_SPI|" "$DIR/device.env"
EUI=$(echo "$EUI" | tr '[:lower:]' '[:upper:]')
sed -e "s|/dev/spidev0.0|$NEON_SPI|" -e "s|AA555A0000000000|$EUI|" \
    -e "s|\"spread_factor\": 11|\"spread_factor\": $SF|" \
    "$HW/configs/global_conf.$CHIP.$REGION.json" > "$DIR/global_conf.json"
grep -q "\"spread_factor\": $SF\b" "$DIR/global_conf.json" || die "could not set the service channel to SF$SF"

PRESTART=""
if [ "$CHIP" = sx1301 ]; then
    # The SX1302 forwarder resets the chip itself; the SX1301 one does not.
    PRESTART="ExecStartPre=$DIR/reset_lgw.sh start"
fi
cat > /etc/systemd/system/neon-forwarder.service <<EOF
[Unit]
Description=Neon: patched Semtech packet forwarder ($CHIP, $REGION)
After=network-online.target

[Service]
WorkingDirectory=$DIR
$PRESTART
ExecStart=$DIR/lora_pkt_fwd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
# The unit names the env file and the update guard under /opt/neon: follow NEON_PREFIX.
sed "s|/opt/neon/|$PREFIX/|g" "$HW/systemd/neond.service" > /etc/systemd/system/neond.service
chmod 644 /etc/systemd/system/neond.service
install -m 755 "$HW/scripts/update-guard.sh" "$PREFIX/update-guard.sh"
if [ ! -f "$PREFIX/neond.env" ]; then
    cp "$HW/systemd/neond.env.$REGION" "$PREFIX/neond.env"
fi
# Keep neond on the same preset as the forwarder (neond sets the forwarder's service channel
# to its preset at each start). Its default channel is named after the preset. NEON_PRESET is
# a starting value the panel can change; --preset in NEOND_ARGS (before 0.4.126) would lock it
# there, so it moves out. Settings the panel saved get the preset given here too.
sed -i '/^NEON_PRESET=/d; /^NEOND_ARGS=/s/--preset [A-Za-z]* *//' "$PREFIX/neond.env"
echo "NEON_PRESET=$PRESET" >> "$PREFIX/neond.env"
if [ -f "$PREFIX/neond.toml" ]; then
    sed -i "s/^preset *= *\".*\"/preset = \"$PRESET\"/" "$PREFIX/neond.toml"
fi
if grep -q -- "^NEOND_ARGS=.*--channel" "$PREFIX/neond.env"; then
    echo "NOTE: $PREFIX/neond.env sets --channel. For the default $PRESET channel, remove it (neond derives it from the preset)."
fi
systemctl daemon-reload

cat <<EOF

Installed the $CHIP forwarder for $REGION in $DIR (gateway EUI $EUI), preset $PRESET (SF$SF BW250).

Next steps (hardware/README.md explains each one):
  1. Run the forwarder in the foreground once:  sudo $DIR/run.sh   (log in $DIR/logs/)
  2. Build neond and copy it to /usr/local/bin/neond
  3. Edit $PREFIX/neond.env, then run both as services:
       systemctl enable --now neon-forwarder neond
EOF
