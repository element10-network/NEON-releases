#!/bin/sh
# Weekly token epoch on a hub (neon-epoch.timer runs it daily; nothing happens until the
# next epoch's week is over). For the epoch whose root comes next on chain it:
#   1. lists the registered hubs from the chain (neon-token hubs),
#   2. computes the epoch from the signed day logs (neon-oracle, continuing from the
#      previous epoch's result in epochs/),
#   3. checks every proof (neon-oracle --check),
#   4. posts the root (POST=1, the admin key is on this machine) and publishes the file in
#      epochs/, where the hub hands it to stations' claim pages.
# With POST=0 (the admin is a multisig) the result goes to epochs/pending/ instead: post its
# root with the multisig, then move the file to epochs/.
#
# Runs as the hub user (neon-epoch.service: User=ne), which owns reports/epochs.
# Settings: /etc/neon/epoch.conf (NEON_EPOCH_CONF to use another file; root's, readable), KEY=VALUE:
#   LAUNCH=2026-10-12          first day of epoch 0 (a Monday)
#   TREASURY=<address>         receives the treasury share
#   NEON_TOKEN=/home/ne/NEON-token/target/release/neon-token
#   NEON_ORACLE=/home/ne/NEON/target/release/neon-oracle
#   KEYPAIR=/home/ne/.config/solana/id.json   the admin key (POST=1)
#   URL=devnet                 devnet | mainnet | localhost | an RPC URL
#   REPORTS=/var/lib/neon/reports
#   POST=1
#   IGNORE_OPERATORS=0         1: bench mode (one operator's test stations)
#   HARDWARE_FROM=YYYY-MM-DD   from this day only atoms signed by an onboarded Helium hotspot's
#                              ECC608 earn (docs/DIRECTORY.md; the hub's onboarded.json in REPORTS,
#                              kept by neond --hardware-from with the same date)
#   FORCE=0                    1: compute even if the week is not over (tests only)
#   NO_HUBS_OK=0               1: an empty hub registry is believed (tests, a network without
#                              electrodes); otherwise an empty one stops the run
set -eu
export RUST_BACKTRACE=0
CONF=${NEON_EPOCH_CONF:-/etc/neon/epoch.conf}
[ -f "$CONF" ] || { echo "no settings: $CONF"; exit 1; }
. "$CONF"
: "${LAUNCH:?LAUNCH missing in $CONF}" "${TREASURY:?TREASURY missing in $CONF}"
: "${NEON_TOKEN:?NEON_TOKEN missing in $CONF}" "${NEON_ORACLE:?NEON_ORACLE missing in $CONF}"
URL=${URL:-devnet}
REPORTS=${REPORTS:-/var/lib/neon/reports}
POST=${POST:-1}
KEYPAIR=${KEYPAIR:-}
EPOCHS=$REPORTS/epochs
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

tok() {
    if [ -n "$KEYPAIR" ]; then
        "$NEON_TOKEN" --url "$URL" --keypair "$KEYPAIR" "$@"
    else
        "$NEON_TOKEN" --url "$URL" "$@"
    fi
}

if ! mkdir -p "$EPOCHS/pending" 2>/dev/null || [ ! -w "$EPOCHS" ] || [ ! -w "$EPOCHS/pending" ]; then
    echo "$(id -un) cannot write $EPOCHS: sudo chown -R $(id -un): $EPOCHS"
    exit 1
fi
N=$(tok next-epoch)
if [ "$POST" != 1 ] && [ -f "$EPOCHS/pending/epoch-$N.json" ]; then
    echo "epoch $N is computed and waits for its root to be posted: $EPOCHS/pending/epoch-$N.json"
    exit 0
fi

OUT=$WORK/epoch-$N.json
set -- --launch "$LAUNCH" --treasury "$TREASURY" --epoch "$N" --out "$OUT"
if [ "$N" -gt 0 ]; then
    PREV=$EPOCHS/epoch-$((N - 1)).json
    # A post that reached the chain but exited with an error left its result pending: the
    # chain says that epoch is posted (it gave N), so it is the previous result.
    PENDING=$EPOCHS/pending/epoch-$((N - 1)).json
    if [ ! -f "$PREV" ] && [ -f "$PENDING" ] && [ "$POST" = 1 ]; then
        mv "$PENDING" "$PREV"
        echo "epoch $((N - 1)) was posted after all: published from pending"
    fi
    [ -f "$PREV" ] || { echo "epoch $((N - 1))'s result is missing: $PREV"; exit 1; }
    set -- "$@" --previous "$PREV"
fi
# The hub registry. An empty answer may be the RPC's (devnet's public RPC sometimes lists no
# accounts: epoch 0 was computed without the registered electrode, 2026-10-27), so it is asked
# again, and an empty one stops the run instead of computing an epoch in which no hub earns (a
# posted epoch cannot be changed); the timer tries again the next day. NO_HUBS_OK=1 believes it.
has_hubs() { [ -n "$(tr -d ' \n{}' < "$WORK/hubs.json")" ]; }
for try in 1 2 3; do
    tok hubs > "$WORK/hubs.json"
    has_hubs && break
    [ "$try" -lt 3 ] && sleep 20
done
if has_hubs; then
    set -- "$@" --hubs "$WORK/hubs.json"
elif [ "${NO_HUBS_OK:-0}" = 1 ]; then
    echo "no registered hubs on chain: every signed log counts, hubs earn nothing (NO_HUBS_OK=1)"
else
    echo "the hub registry came back empty three times: epoch $N not computed (an RPC fault? NO_HUBS_OK=1 in $CONF if there really are none). The timer tries again; or check: $NEON_TOKEN --url $URL hubs"
    exit 1
fi
[ "${IGNORE_OPERATORS:-0}" = 1 ] && set -- "$@" --ignore-operators
if [ -n "${HARDWARE_FROM:-}" ]; then
    [ -f "$REPORTS/onboarded.json" ] || { echo "HARDWARE_FROM set but $REPORTS/onboarded.json is missing (neond --hardware-from keeps it)"; exit 1; }
    set -- "$@" --hardware-from "$HARDWARE_FROM" --onboarded "$REPORTS/onboarded.json"
fi
[ "${FORCE:-0}" = 1 ] && set -- "$@" --force

if ! out=$("$NEON_ORACLE" "$@" "$REPORTS" 2>&1); then
    case "$out" in
        *"is not over"*) echo "$out" | head -n 1 | sed 's/^Error: //'; exit 0 ;;
    esac
    echo "$out"
    exit 1
fi
echo "$out"
"$NEON_ORACLE" --check "$OUT"

if [ "$POST" = 1 ]; then
    # Kept before posting: a post that sends but exits with an error (an RPC timeout) must not
    # lose the result, or the next epoch could never find it.
    mkdir -p "$EPOCHS/pending"
    install -m 644 "$OUT" "$EPOCHS/pending/epoch-$N.json"
    # From epoch 1, neon-token checks that the result this one builds on is the root on chain.
    if ! tok post "$OUT" ${PREV:+--previous "$PREV"}; then
        echo "post failed; the checked result is at $EPOCHS/pending/epoch-$N.json (check the chain for epoch $N before posting it again)"
        exit 1
    fi
    mv "$EPOCHS/pending/epoch-$N.json" "$EPOCHS/epoch-$N.json"
    echo "epoch $N posted and published: $EPOCHS/epoch-$N.json"
else
    mkdir -p "$EPOCHS/pending"
    install -m 644 "$OUT" "$EPOCHS/pending/epoch-$N.json"
    echo "epoch $N computed: post its root with the multisig, then move $EPOCHS/pending/epoch-$N.json to $EPOCHS/"
fi
