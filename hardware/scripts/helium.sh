#!/bin/sh
# Keep a Neon station working as a Helium hotspot (docs/HELIUM.md): install Helium's own
# gateway software (gateway-rs), using the hotspot's ECC608 identity, and pass the
# station's LoRaWAN traffic to it (neond's `lorawan` setting).
#
# Run on the station, as root, from a checkout of this repository, after install.sh:
#   sudo hardware/scripts/helium.sh <device> [region]
#
#   device  rak-v2 (see hardware/devices/; needs NEON_ECC_I2C_BUS)
#   region  EU868 (default) or US915: used until Helium sends the asserted one
#
# Proof of Coverage is retired (HIP 149), so beacons stay off ([poc] disable = true);
# the hotspot carries LoRaWAN data for Helium sensors and keeps its data-transfer rewards.
# `sudo hardware/scripts/helium.sh --remove` stops it and turns the pass-through off.

set -eu

die() { echo "ERROR: $*" >&2; exit 1; }

VERSION=1.3.0
# Helium's release builds (with ECC608 support), pinned by checksum.
URL=https://github.com/helium/gateway-rs/releases/download/v$VERSION
AARCH64=helium-gateway-$VERSION-aarch64-unknown-linux-musl.tar.gz
AARCH64_SHA=8462e792592b24aae8fff587185ec59080e818ff2fff132dde7dd5eafdabbf2d
ARMHF=helium-gateway-$VERSION-arm-unknown-linux-gnueabihf.tar.gz
ARMHF_SHA=affbfe853da75f4b62010045b1352a84fdee5789d869e63e5a27c1309a98485b

HW=$(cd "$(dirname "$0")/.." && pwd)
PREFIX=${NEON_PREFIX:-/opt/neon}
GW_DIR=/opt/helium_gateway
CONF_DIR=/etc/helium_gateway
UNIT=/etc/systemd/system/helium-gateway.service
TOML=$PREFIX/neond.toml
ENV=$PREFIX/neond.env
LORAWAN=127.0.0.1:1680

[ "$(id -u)" -eq 0 ] || die "run as root"
[ $# -ge 1 ] || die "usage: $0 <device> [EU868|US915]   or   $0 --remove"

# set_lorawan VALUE: neond's `lorawan` setting (empty: removed), in neond.toml and as the
# starting value NEON_LORAWAN in neond.env (before the first-run setup there is no neond.toml;
# the setup page then saves it there).
set_lorawan() {
    if [ -f "$ENV" ]; then
        sed -i '/^NEON_LORAWAN=/d' "$ENV"
        [ ! -s "$ENV" ] || [ "$(tail -c 1 "$ENV" | od -An -c | tr -d ' ')" = '\n' ] || echo >> "$ENV"
        [ -z "$1" ] || echo "NEON_LORAWAN=$1" >> "$ENV"
    fi
    [ -f "$TOML" ] || return 0
    sed -i '/^lorawan *=/d' "$TOML"
    # A last line without its newline would run into the new one.
    [ ! -s "$TOML" ] || [ "$(tail -c 1 "$TOML" | od -An -c | tr -d ' ')" = '\n' ] || echo >> "$TOML"
    [ -z "$1" ] || printf 'lorawan = "%s"\n' "$1" >> "$TOML"
    chmod 600 "$TOML"
}

if [ "$1" = "--remove" ]; then
    systemctl disable --now helium-gateway 2>/dev/null || true
    set_lorawan ""
    systemctl restart neond 2>/dev/null || true
    echo "Helium gateway stopped and disabled; LoRaWAN pass-through off. Files stay in $GW_DIR and $CONF_DIR."
    exit 0
fi

# neond 0.4.23 and later know the setting; an older one would refuse its settings file.
neond --help 2>/dev/null | grep -q -- '--lorawan' \
    || die "update the station to 0.4.23 or later first (panel: Settings → Updates)"
# Before the first-run setup (no neond.toml: setup.sh runs this at install time) the setting
# goes into neond.env, which only neond 0.4.126 and later read.
[ -f "$TOML" ] || neond --help 2>/dev/null | grep -q NEON_LORAWAN \
    || die "finish the station's first-run setup in its panel first (no $TOML yet)"

DEVICE=$1
REGION=${2:-EU868}
ENV_FILE=$HW/devices/$DEVICE.env
[ -f "$ENV_FILE" ] || die "unknown device '$DEVICE' (no $ENV_FILE)"
case "$REGION" in EU868|US915) ;; *) die "unknown region '$REGION'" ;; esac
. "$ENV_FILE"
[ -n "${NEON_ECC_I2C_BUS:-}" ] || die "$DEVICE has no ECC608 (NEON_ECC_I2C_BUS in $ENV_FILE)"
BUS=$NEON_ECC_I2C_BUS

# The ECC608 is on I2C: turn the bus on (Raspberry Pi OS) if it is not.
if [ ! -e "/dev/i2c-$BUS" ]; then
    if command -v raspi-config >/dev/null; then
        raspi-config nonint do_i2c 0
        modprobe i2c-dev || true
    fi
    [ -e "/dev/i2c-$BUS" ] || die "/dev/i2c-$BUS missing: enable I2C (raspi-config, Interface Options)"
fi

case "$(uname -m)" in
    aarch64) PKG=$AARCH64; SHA=$AARCH64_SHA ;;
    armv7l|armv6l) PKG=$ARMHF; SHA=$ARMHF_SHA ;;
    *) die "no Helium build for $(uname -m)" ;;
esac

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
echo "Downloading gateway-rs $VERSION"
curl -fsSL -o "$TMP/gw.tgz" "$URL/$PKG"
echo "$SHA  $TMP/gw.tgz" | sha256sum -c - >/dev/null || die "checksum mismatch for $PKG"
tar -xzf "$TMP/gw.tgz" -C "$TMP"
mkdir -p "$GW_DIR" "$CONF_DIR"
cp "$TMP/helium_gateway" "$GW_DIR/helium_gateway.new" && mv -f "$GW_DIR/helium_gateway.new" "$GW_DIR/helium_gateway"
chmod 755 "$GW_DIR/helium_gateway"

# Settings: Helium's own file, with the ECC608 key, the region until the asserted one
# arrives, no PoC beacons, and the packet-forwarder port neond passes traffic to.
# An existing file is kept (it may hold the owner's changes).
CONF=$CONF_DIR/settings.toml
if [ ! -f "$CONF" ]; then
    sed -e "s|^keypair = .*|keypair = \"ecc://i2c-$BUS:96?slot=0\"|" \
        -e "s|^# *onboarding = .*|onboarding = \"ecc://i2c-$BUS:96?slot=15\"|" \
        -e "s|^# *region = .*|region = \"$REGION\"|" \
        -e "s|^# *disable = false|disable = true|" \
        -e "s|^listen = .*|listen = \"$LORAWAN\"|" \
        -e "s|^timestamp = true|timestamp = false|" \
        "$TMP/settings.toml" > "$CONF.new"
    for want in "keypair = \"ecc://" "onboarding = \"ecc://" "region = \"$REGION\"" "disable = true" "listen = \"$LORAWAN\""; do
        grep -q "^$want" "$CONF.new" || die "could not set '$want' in Helium's settings.toml (format changed?)"
    done
    mv "$CONF.new" "$CONF"
elif ! grep -q "^region = \"$REGION\"" "$CONF"; then
    # Kept (it may hold the owner's changes), but the region asked for now is set.
    sed -i "s|^#* *region = .*|region = \"$REGION\"|" "$CONF"
    echo "region in $CONF set to $REGION"
fi

cat > "$UNIT" <<EOF
[Unit]
Description=Helium gateway (gateway-rs), fed LoRaWAN traffic by neond
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$GW_DIR/helium_gateway -c $CONF server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable helium-gateway
systemctl restart helium-gateway

set_lorawan "$LORAWAN"
systemctl restart neond 2>/dev/null || true

sleep 5
echo
echo "Helium gateway installed and running; neond passes LoRaWAN traffic to $LORAWAN."
echo "Hotspot identity (from the ECC608):"
"$GW_DIR/helium_gateway" -c "$CONF" info key name region router 2>&1 || echo "(not answering yet: try again in a minute)"
echo
echo "Logs: journalctl -u helium-gateway -f"
