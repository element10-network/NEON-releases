#!/bin/sh
# One-line Neon station install, on a fresh Raspberry Pi OS Lite (64-bit):
#
#   curl -fsSL https://raw.githubusercontent.com/element10-network/NEON-releases/main/hardware/scripts/setup.sh | sudo sh
#
# element10-network/NEON-releases is public: the signed releases and these scripts (the Release
# workflow copies them there from the private source, element10-network/NEON). No token is
# needed, except to build from the source (NEON_SOURCE=1 NEON_TOKEN=...); the token is then
# kept in /opt/neon/github.token (readable by root only) for later runs.
#
# Installs the patched packet forwarder (install.sh), the newest signed neond
# release (or builds it from source if there is none), the systemd services, and
# starts the web panel on port 8080, where the first-run setup page asks for a
# station name and password. Run it again to repair or reinstall; settings stay.
# network.sh then gives the station a local name (http://<hostname>.local, port 80 leads to
# the panel) and, with Wi-Fi, the setup hotspot for when it has no network.
#
# Options, as environment variables (put them after sudo: sudo NEON_PRESET=ShortFast sh):
#   NEON_DEVICE   rak-v2 (default) | nebra-rockpi4      see hardware/devices/
#   NEON_REGION   EU868 (default) | US915; a rerun keeps the installed one
#   NEON_PRESET   the local mesh's Meshtastic preset (default LongFast; a rerun keeps the installed one)
#   NEON_REF      git branch or tag to install from (default main)
#   NEON_SOURCE=1 build neond from the private source instead of downloading the release
#   NEON_TOKEN    with NEON_SOURCE=1: GitHub token for the source (fine-grained, Contents: read-only)
set -eu
# Under systemd (the SD image's first boot) HOME is not set; rustup and cargo need it.
export HOME="${HOME:-/root}"

PREFIX=/opt/neon
# A rerun keeps the station's region and preset (from neond.env) unless given again.
ENV_ARGS=$(sed -n 's/^NEOND_ARGS=//p' "$PREFIX/neond.env" 2>/dev/null || true)
OLD_PRESET=$(printf '%s' "$ENV_ARGS" | sed -n 's/.*--preset \([A-Za-z]*\).*/\1/p')
case "$(printf '%s' "$ENV_ARGS" | sed -n 's/.*--region \([A-Za-z0-9_]*\).*/\1/p')" in
    US) OLD_REGION=US915 ;;
    EU_868) OLD_REGION=EU868 ;;
    *) OLD_REGION="" ;;
esac
DEVICE=${NEON_DEVICE:-rak-v2}
REGION=${NEON_REGION:-${OLD_REGION:-EU868}}
PRESET=${NEON_PRESET:-${OLD_PRESET:-LongFast}}
REF=${NEON_REF:-main}
REPO=$PREFIX/src/NEON
# The public releases and scripts; the private source (NEON_SOURCE=1 only).
GH_REPO=element10-network/NEON-releases
SRC_REPO=element10-network/NEON
BIN=/usr/local/bin/neond
TOKEN_FILE=$PREFIX/github.token

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[ "$(id -u)" = 0 ] || die "run as root (curl ... | sudo sh)"
command -v apt-get >/dev/null || die "this installer needs Raspberry Pi OS or another Debian system"

step "Packages"
# On a first boot apt-daily may hold the lock for a while: wait for it.
apt-get -o DPkg::Lock::Timeout=300 update -q
apt-get -o DPkg::Lock::Timeout=300 install -y -q git build-essential curl ca-certificates openssl jq

# GitHub token, for the private source only: given now (kept for later), or kept from an earlier
# run. Without NEON_SOURCE a token kept from the time the code had to be read with one is
# removed (the releases are public now).
mkdir -p "$PREFIX"
TOKEN=""
if [ "${NEON_SOURCE:-}" = 1 ]; then
    if [ -n "${NEON_TOKEN:-}" ]; then
        (umask 077 && printf '%s\n' "$NEON_TOKEN" > "$TOKEN_FILE")
    fi
    TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || true)
    FROM=$SRC_REPO
else
    rm -f "$TOKEN_FILE"
    FROM=$GH_REPO
fi
# git with the token as an HTTP header (not stored in the repository's config).
git_gh() {
    if [ -n "$TOKEN" ]; then
        # Through the environment, not the command line (which every local user can see).
        GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
            GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)" \
            git "$@"
    else
        git "$@"
    fi
}
step "Scripts ($FROM, $REF) in $REPO"
mkdir -p "$PREFIX/src"
# A copy cloned from elsewhere (the old enzyme42/NEON, or the other of the two) is replaced.
if [ -d "$REPO/.git" ] && [ "$(git -C "$REPO" remote get-url origin 2>/dev/null)" != "https://github.com/$FROM.git" ]; then
    rm -rf "$REPO"
fi
if [ -d "$REPO/.git" ]; then
    git_gh -C "$REPO" fetch -q --depth 1 origin "$REF"
    git_gh -C "$REPO" checkout -q -f FETCH_HEAD
else
    git_gh clone -q --depth 1 --branch "$REF" "https://github.com/$FROM.git" "$REPO" \
        || die "could not clone $FROM${NEON_SOURCE:+ (the private source: give NEON_TOKEN)}"
fi

if ! ls /dev/spidev* >/dev/null 2>&1 && command -v raspi-config >/dev/null; then
    step "Turning SPI on"
    raspi-config nonint do_spi 0 || true
    ls /dev/spidev* >/dev/null 2>&1 || die "SPI is still off: reboot, then run this again"
fi

# neond's region name (backbone topic, channel links) for the forwarder's region.
case "$REGION" in
    US915) NEOND_REGION=US ;;
    *) NEOND_REGION=EU_868 ;;
esac

# neond starts with the panel open (no password) until the setup page has saved settings.
if [ ! -f "$PREFIX/neond.env" ]; then
    mkdir -p "$PREFIX"
    cat > "$PREFIX/neond.env" <<EOF
# neond options. Settings made in the web panel are in $PREFIX/neond.toml;
# options here override them (and are locked in the panel).
NEOND_ARGS=--preset $PRESET --region $NEOND_REGION --web 0.0.0.0:8080
EOF
elif grep -q -- '--region ' "$PREFIX/neond.env"; then
    # A rerun (perhaps with another region): neond follows it (install.sh updates the preset).
    sed -i "s/--region [A-Za-z0-9_]*/--region $NEOND_REGION/" "$PREFIX/neond.env"
else
    sed -i "s/^NEOND_ARGS=/NEOND_ARGS=--region $NEOND_REGION /" "$PREFIX/neond.env"
fi

# The concentrator probe needs the SPI device to itself; both start again at the end, and
# also if a step fails on the way (a repair run must not leave the station down).
on_exit() {
    [ -n "${tmp:-}" ] && rm -rf "$tmp"
    if [ -n "${STOPPED:-}" ]; then
        systemctl start neon-forwarder neond 2>/dev/null || true
    fi
}
trap on_exit EXIT
STOPPED=1
systemctl stop neond neon-forwarder 2>/dev/null || true

step "Packet forwarder ($DEVICE, $REGION, $PRESET)"
sh "$REPO/hardware/scripts/install.sh" "$DEVICE" "$REGION" auto "$PRESET"

# The target triple of this system, as release files name it. The userland decides, not
# the kernel: 32-bit Pi OS runs a 64-bit kernel on a Pi 4.
case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    arm64|aarch64) TARGET=aarch64-unknown-linux-gnu ;;
    armhf|armv7l) TARGET=armv7-unknown-linux-gnueabihf ;;
    amd64|x86_64) TARGET=x86_64-unknown-linux-gnu ;;
    *) TARGET=unknown ;;
esac

# Download the signed release: check release.sig against the keys in the source
# (hardware/release-keys.txt), then the binary's size and SHA-256 against release.txt.
download_release() {
    tmp=$(mktemp -d)   # removed on exit (on_exit)
    curl -fsSL -H "Accept: application/vnd.github+json" -o "$tmp/latest.json" \
        "https://api.github.com/repos/$GH_REPO/releases/latest" || { echo "no release found"; return 1; }
    # asset NAME FILE: download a file of the latest release (the API redirects to the file).
    asset() {
        id=$(jq -r --arg n "$1" '.assets[] | select(.name == $n) | .id' "$tmp/latest.json")
        [ -n "$id" ] || { echo "the release has no $1"; return 1; }
        curl -fsSL -L -H "Accept: application/octet-stream" -o "$2" \
            "https://api.github.com/repos/$GH_REPO/releases/assets/$id"
    }
    asset release.txt "$tmp/release.txt" || return 1
    asset release.sig "$tmp/release.sig" || return 1
    # A release that fails its checks is refused, not replaced by a build from source (return 2);
    # only no release, no keys yet or no binary for this target falls back (return 1).
    keys=$(grep -v '^#' "$REPO/hardware/release-keys.txt" | grep -v '^ *$' || true)
    [ -n "$keys" ] || { echo "no release keys yet"; return 1; }
    ok=""
    for key in $keys; do
        # An Ed25519 public key in DER: fixed prefix + the 32 raw bytes.
        { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; echo "$key" | base64 -d; } > "$tmp/key.der"
        if openssl pkeyutl -verify -pubin -keyform DER -inkey "$tmp/key.der" -rawin \
            -in "$tmp/release.txt" -sigfile "$tmp/release.sig" >/dev/null 2>&1; then
            ok=1
            break
        fi
    done
    [ -n "$ok" ] || { echo "release signature not valid"; return 2; }
    line=$(grep "^file $TARGET " "$tmp/release.txt") || { echo "no release binary for $TARGET"; return 1; }
    name=$(echo "$line" | cut -d' ' -f3)
    size=$(echo "$line" | cut -d' ' -f4)
    sha=$(echo "$line" | cut -d' ' -f5)
    asset "$name" "$tmp/neond" || return 1
    [ "$(wc -c < "$tmp/neond")" = "$size" ] || { echo "size mismatch"; return 2; }
    echo "$sha  $tmp/neond" | sha256sum -c --quiet - || { echo "SHA-256 mismatch"; return 2; }
    # It takes the old one's place only once it runs here (a binary built for another libc
    # or target would otherwise leave the atom with no working neond).
    install -m 755 "$tmp/neond" "$BIN.new" || return 1
    "$BIN.new" --version >/dev/null 2>&1 || { echo "the release binary does not run here"; rm -f "$BIN.new"; return 1; }
    mv -f "$BIN.new" "$BIN" || return 1
    echo "installed release $(sed -n 's/^version //p' "$tmp/release.txt")"
}

build_from_source() {
    if ! command -v cargo >/dev/null && [ ! -x "$HOME/.cargo/bin/cargo" ]; then
        curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
    fi
    PATH="$HOME/.cargo/bin:$PATH"
    (cd "$REPO" && cargo build --release --locked -p neond)
    install -m 755 "$REPO/target/release/neond" "$BIN.new"
    "$BIN.new" --version >/dev/null
    mv -f "$BIN.new" "$BIN"
}

step "neond"
if [ "${NEON_SOURCE:-}" = 1 ]; then
    build_from_source
else
    rc=0
    download_release || rc=$?
    if [ "$rc" = 2 ]; then
        die "the release did not pass its checks (signature, size or SHA-256): not installed. Try again later."
    elif [ "$rc" != 0 ]; then
        die "no usable release for this atom ($TARGET). The source is private: NEON_SOURCE=1 NEON_TOKEN=... builds from it."
    fi
fi
"$BIN" --version

step "Local name and Wi-Fi setup"
sh "$REPO/hardware/scripts/network.sh" || echo "local name / hotspot not set up (the panel still works by address)"

step "Services"
systemctl daemon-reload
systemctl enable -q neon-forwarder neond
systemctl restart neon-forwarder neond
STOPPED=""

IP=$(hostname -I 2>/dev/null | cut -d' ' -f1)
cat <<EOF

Neon is installed. Open the panel to finish the setup:

    http://$(hostname).local       (or http://${IP:-<this station's address>}:8080)

Logs: journalctl -u neond -f      (forwarder: journalctl -u neon-forwarder -f)
EOF
