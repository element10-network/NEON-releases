#!/bin/sh
# Download a signed neond release for this container's architecture and check it, as setup.sh
# does: release.sig against the keys in hardware/release-keys.txt, then the binary's size and
# SHA-256 against release.txt. Used by the Dockerfile (build time only).
#   fetch-release.sh KEYS_FILE OUT_BINARY [VERSION]   (VERSION: e.g. 0.9.6; never older than setup.sh's MIN_RELEASE; default the latest)
set -eu
KEYS=$1
OUT=$2
VERSION=${3:-latest}
REPO=${NEON_RELEASES:-element10-network/NEON-releases}
case "$(uname -m)" in
    aarch64|arm64) TARGET=aarch64-unknown-linux-gnu ;;
    x86_64|amd64) TARGET=x86_64-unknown-linux-gnu ;;
    *) echo "no neond release for $(uname -m)"; exit 1 ;;
esac
if [ "$VERSION" = latest ]; then
    BASE="https://github.com/$REPO/releases/latest/download"
else
    BASE="https://github.com/$REPO/releases/download/v${VERSION#v}"
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/release.txt" "$BASE/release.txt"
curl -fsSL -o "$tmp/release.sig" "$BASE/release.sig"
ok=""
for key in $(grep -v '^#' "$KEYS" | grep -v '^ *$'); do
    # An Ed25519 public key in DER: fixed prefix + the 32 raw bytes.
    { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; echo "$key" | base64 -d; } > "$tmp/key.der"
    if openssl pkeyutl -verify -pubin -keyform DER -inkey "$tmp/key.der" -rawin \
        -in "$tmp/release.txt" -sigfile "$tmp/release.sig" >/dev/null 2>&1; then
        ok=1
        break
    fi
done
[ -n "$ok" ] || { echo "release signature not valid"; exit 1; }
# A pinned version: the signed file must say it is that one (not an older release under its tag).
if [ "$VERSION" != latest ]; then
    got=$(sed -n 's/^version //p' "$tmp/release.txt")
    [ "$got" = "${VERSION#v}" ] || { echo "release.txt is version $got, not ${VERSION#v}"; exit 1; }
fi
# Never older than setup.sh's floor (review 2026-11-16: an old signed release marked "latest" would
# otherwise be built into the image), read from the setup.sh beside this script when it is there.
min=""
if [ -f "$(dirname "$0")/setup.sh" ]; then
    min=$(sed -n 's/^ *MIN_RELEASE=["'"'"']*\([0-9][0-9.]*\).*/\1/p' "$(dirname "$0")/setup.sh" | head -n 1)
    # Beside it but unreadable: refused, not skipped without a word.
    [ -n "$min" ] || { echo "setup.sh has no MIN_RELEASE this script can read: not built"; exit 1; }
fi
got=$(sed -n 's/^version //p' "$tmp/release.txt")
if [ -n "$min" ] && [ "$(printf '%s\n%s\n' "$min" "${got%%+*}" | sort -V | head -n 1)" != "$min" ]; then
    echo "release $got is older than $min (setup.sh's MIN_RELEASE): not used"; exit 1
fi
line=$(grep "^file $TARGET " "$tmp/release.txt") || { echo "no release binary for $TARGET"; exit 1; }
name=$(echo "$line" | cut -d' ' -f3)
size=$(echo "$line" | cut -d' ' -f4)
sha=$(echo "$line" | cut -d' ' -f5)
curl -fsSL -o "$tmp/neond" "$BASE/$name"
[ "$(wc -c < "$tmp/neond")" = "$size" ] || { echo "size mismatch"; exit 1; }
echo "$sha  $tmp/neond" | sha256sum -c --quiet - || { echo "SHA-256 mismatch"; exit 1; }
install -m 755 "$tmp/neond" "$OUT"
"$OUT" --version
echo "release $(sed -n 's/^version //p' "$tmp/release.txt") for $TARGET, signature and SHA-256 checked"
