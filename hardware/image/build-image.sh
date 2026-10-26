#!/bin/sh
# Build a Neon station SD image: Raspberry Pi OS Lite (64-bit) with SPI on, the packages
# setup.sh needs, and a first-boot service that installs the station (neon-firstboot).
# Settings go in neon.txt on the card's boot partition (readable from any computer).
#
# Run as root on an arm64 Linux machine (the "SD image" workflow uses GitHub's arm64
# runner; the chroot needs no emulation there):
#
#   sudo sh hardware/image/build-image.sh neon-station.img.xz
#
# NEON_BASE_IMAGE: another Raspberry Pi OS image (URL) to start from; NEON_BASE_SHA256 its
# SHA-256 (by default the one published next to it).
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
OUT=${1:-neon-station.img.xz}
BASE_URL=${NEON_BASE_IMAGE:-https://downloads.raspberrypi.com/raspios_lite_arm64_latest}

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo "run on arm64 (the chroot runs the image's programs)" >&2; exit 1; }
for t in curl xz parted losetup e2fsck resize2fs chroot; do
    command -v "$t" >/dev/null || { echo "missing: $t" >&2; exit 1; }
done

WORK=$(mktemp -d)
ROOT=$WORK/root
LOOP=""
cleanup() {
    for m in dev/pts dev sys proc boot/firmware; do umount "$ROOT/$m" 2>/dev/null || true; done
    umount "$ROOT" 2>/dev/null || true
    [ -n "$LOOP" ] && losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "==> Base image: $BASE_URL"
# "latest" redirects to a dated file; Raspberry Pi publishes its SHA-256 next to it.
URL=$(curl -fsSL -r 0-0 -o /dev/null -w '%{url_effective}' "$BASE_URL")
echo "    $URL"
curl -fL --retry 3 -o "$WORK/base.img.xz" "$URL"
WANT=${NEON_BASE_SHA256:-}
if [ -z "$WANT" ]; then
    if ! curl -fsSL --retry 3 -o "$WORK/base.sha256" "$URL.sha256"; then
        echo "no SHA-256 published for the base image at $URL.sha256 (set NEON_BASE_SHA256)" >&2; exit 1
    fi
    WANT=$(cut -d' ' -f1 < "$WORK/base.sha256")
fi
[ -n "$WANT" ] || { echo "empty SHA-256 file for the base image (set NEON_BASE_SHA256)" >&2; exit 1; }
echo "$WANT  $WORK/base.img.xz" | sha256sum -c - || { echo "base image SHA-256 mismatch" >&2; exit 1; }
xz -d "$WORK/base.img.xz"
IMG=$WORK/base.img

echo "==> Room for the packages (+1 GiB)"
truncate -s +1G "$IMG"
parted -s "$IMG" resizepart 2 100%
LOOP=$(losetup -fP --show "$IMG")
# The partition devices appear a moment later.
partprobe "$LOOP" 2>/dev/null || true
udevadm settle 2>/dev/null || true
i=0
until [ -b "${LOOP}p2" ]; do
    i=$((i + 1))
    [ "$i" -le 20 ] || { echo "no ${LOOP}p2" >&2; exit 1; }
    sleep 0.5
done
e2fsck -fy "${LOOP}p2" || [ $? -le 1 ]
resize2fs "${LOOP}p2"

mkdir -p "$ROOT"
mount "${LOOP}p2" "$ROOT"
mount "${LOOP}p1" "$ROOT/boot/firmware"
for m in proc sys dev dev/pts; do mount --bind "/$m" "$ROOT/$m"; done

echo "==> Packages"
cp "$ROOT/etc/resolv.conf" "$WORK/resolv.conf" 2>/dev/null || true
cp /etc/resolv.conf "$ROOT/etc/resolv.conf"
# No services start inside the chroot.
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"
chmod 755 "$ROOT/usr/sbin/policy-rc.d"
chroot "$ROOT" sh -c 'apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q git build-essential curl ca-certificates openssl jq && apt-get clean'
rm -f "$ROOT/usr/sbin/policy-rc.d"
if [ -f "$WORK/resolv.conf" ]; then cp "$WORK/resolv.conf" "$ROOT/etc/resolv.conf"; fi

echo "==> SPI on, first-boot service, neon.txt"
CFG=$ROOT/boot/firmware/config.txt
grep -q '^dtparam=spi=on' "$CFG" || echo 'dtparam=spi=on' >> "$CFG"
install -d "$ROOT/opt/neon/image"
install -m 755 "$REPO/hardware/scripts/setup.sh" "$ROOT/opt/neon/image/setup.sh"
install -m 755 "$HERE/neon-firstboot.sh" "$ROOT/usr/local/sbin/neon-firstboot"
install -m 644 "$HERE/neon-firstboot.service" "$ROOT/etc/systemd/system/neon-firstboot.service"
chroot "$ROOT" systemctl enable neon-firstboot.service
install -m 644 "$HERE/neon.txt" "$ROOT/boot/firmware/neon.txt"
echo "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)" > "$ROOT/opt/neon/image/commit"
echo "$URL $WANT" > "$ROOT/opt/neon/image/base"

echo "==> Image"
sync
for m in dev/pts dev sys proc boot/firmware; do umount "$ROOT/$m"; done
umount "$ROOT"
e2fsck -fy "${LOOP}p2" || [ $? -le 1 ]
losetup -d "$LOOP"
LOOP=""
xz -T0 -6 -c "$IMG" > "$OUT"
sha256sum "$OUT" > "$OUT.sha256"
echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
