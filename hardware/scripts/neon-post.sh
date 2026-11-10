#!/bin/sh
# Posts each epoch's root from home (owner 2026-11-03: the admin key stays at home; the electrode
# computes the epoch at 02:30 UTC on Tuesdays into epochs/pending/). Run daily by neon-post.timer
# on a Pi at home; nothing to do on other days.
#
# For every epoch waiting on the electrode, in order: fetch it and the one it was computed from,
# fetch the signed day logs it was computed from and compute it again here (neon-oracle, owner
# 2026-11-10 decision 5: nothing is posted that this machine did not compute itself, with the
# same root), check with the chain what comes next (neon-token next-epoch), post it with the admin key
# (neon-token checks the file, the proofs and the previous root on chain), then have the
# electrode file it. An epoch already on chain (a run that posted but could not file it) is only
# filed. The electrode lets this key do nothing else (neon-epoch-remote.sh).
#
# Settings: /etc/neon/post.conf, KEY=VALUE:
#   NEON_TOKEN=/home/ne/NEON-token/target/release/neon-token
#   KEYPAIR=/home/ne/.config/solana/id.json   the admin key
#   URL=devnet
#   REMOTE=ne@eu1.element10.network
#   PORT=2222
#   SSH_KEY=/var/lib/neon-post/ssh/id_ed25519
#   NEON_ORACLE=/home/ne/NEON/target/release/neon-oracle   computes each epoch again here
#   TREASURY=<address>   the treasury's wallet (as in the electrode's epoch.conf)
#   LOCAL_EPOCHS=/var/lib/neon/reports/epochs   an electrode on this machine too: it gets each
#                                              posted epoch, so its own claim answers stay current
#                                              (default: this directory, when it exists; this
#                                              user must be able to write it: sudo chown -R ne: it)
set -eu
CONF=${NEON_POST_CONF:-/etc/neon/post.conf}
[ -f "$CONF" ] || { echo "no settings: $CONF"; exit 1; }
. "$CONF"
: "${NEON_TOKEN:?}" "${KEYPAIR:?}" "${REMOTE:?}" "${SSH_KEY:?}"
: "${NEON_ORACLE:?NEON_ORACLE missing in $CONF: each epoch is computed again here before it is posted}"
: "${TREASURY:?TREASURY missing in $CONF (the treasury wallet, as in the electrode's epoch.conf)}"
URL=${URL:-devnet}
PORT=${PORT:-22}
KEEP=${KEEP:-/var/lib/neon-post/epochs}
LOCAL_EPOCHS=${LOCAL_EPOCHS:-/var/lib/neon/reports/epochs}
mkdir -p "$KEEP"
# One run at a time (the timer and one started by hand would both post the same epoch).
exec 9>"$KEEP/.lock"
flock -n 9 || { echo "already running"; exit 0; }

remote() {
    ssh -i "$SSH_KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=30 \
        -o UserKnownHostsFile=/var/lib/neon-post/ssh/known_hosts "$REMOTE" "$@"
}
tok() { "$NEON_TOKEN" --url "$URL" --keypair "$KEYPAIR" "$@"; }
# An electrode on this machine (hq) serves the newest epoch it has to claim pages: given the one
# just posted, it no longer answers with the week before (owner 2026-11-04, hq showed epoch 0).
# Also for an epoch found on chain already (a run that posted, then failed before filing it).
file_local() {
    if [ -d "$LOCAL_EPOCHS" ] && [ -s "$KEEP/epoch-$1.json" ]; then
        cp "$KEEP/epoch-$1.json" "$LOCAL_EPOCHS/.epoch-$1.json.part" &&
            mv "$LOCAL_EPOCHS/.epoch-$1.json.part" "$LOCAL_EPOCHS/epoch-$1.json" &&
            echo "epoch $1 also filed in $LOCAL_EPOCHS" ||
            echo "epoch $1 not filed in $LOCAL_EPOCHS" >&2
    fi
}

waiting=$(remote list)
[ -n "$waiting" ] || { echo "no epoch waiting"; exit 0; }
for n in $waiting; do
    case "$n" in "" | *[!0-9]*) echo "not an epoch number from the electrode: $n" >&2; exit 1 ;; esac
    next=$(tok next-epoch)
    if [ "$n" -lt "$next" ]; then
        echo "epoch $n is on chain already: filing it"
        # The electrode's copy, not one kept here: posted by hand, or kept from a run whose post
        # failed before the electrode computed it again, this one may be missing or another.
        remote get "$n" > "$KEEP/epoch-$n.json.part"
        # Only the one whose root is on chain (another would show "does not match the posted
        # root" on every claim page, and epoch n+1's post would refuse it as its previous).
        if ! tok check "$KEEP/epoch-$n.json.part"; then
            echo "epoch $n: not filed: its file could not be matched with the root on chain (the reason above; a NEON-token CLI older than bd12b03 has no 'check': rebuild it)" >&2
            exit 1
        fi
        mv "$KEEP/epoch-$n.json.part" "$KEEP/epoch-$n.json"
        remote done "$n"
        file_local "$n"
        continue
    fi
    if [ "$n" -gt "$next" ]; then
        echo "epoch $n waits for epoch $next, which is not on chain: not posted" >&2
        exit 1
    fi
    remote get "$n" > "$KEEP/epoch-$n.json.part"
    mv "$KEEP/epoch-$n.json.part" "$KEEP/epoch-$n.json"
    [ "$n" -gt 0 ] || { echo "epoch 0 is not computed again here (genesis): post it by hand" >&2; exit 1; }
    remote prev "$n" > "$KEEP/epoch-$((n - 1)).json.part"
    mv "$KEEP/epoch-$((n - 1)).json.part" "$KEEP/epoch-$((n - 1)).json"
    # The previous result must be the one on chain (checked against its posted root).
    tok check "$KEEP/epoch-$((n - 1)).json" || { echo "epoch $((n - 1)) does not match the root on chain: epoch $n not posted" >&2; exit 1; }
    # Computed again here from the signed logs, with the registry from the chain, the previous
    # epoch's hardware rule, and the electrode's core hubs, onboarded list and excused days (each
    # recorded in its result, shown here).
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    remote logs "$n" | tar xzf - -C "$work" || { echo "epoch $n: its day logs could not be fetched: not posted" >&2; exit 1; }
    # The registry as the chain has it now: a hub registered (or a wallet changed) since the
    # electrode's run gives another root, and the epoch waits (compute it again on the electrode).
    tok hubs > "$work/hubs.json"
    prev="$KEEP/epoch-$((n - 1)).json"
    set -- --launch "$(jq -r .launch "$prev")" --treasury "$TREASURY" --epoch "$n" \
        --previous "$prev" --hubs "$work/hubs.json" --core-hubs "$KEEP/epoch-$n.json" --out "$work/epoch-$n.json"
    echo "epoch $n: core hubs $(jq -c '.core_hubs // []' "$KEEP/epoch-$n.json")"
    from=$(jq -r '.hardware_from // ""' "$prev")
    if [ -n "$from" ]; then
        set -- "$@" --hardware-from "$from" --onboarded "$KEEP/epoch-$n.json"
    fi
    for x in $(jq -r '.excused // [] | .[]' "$KEEP/epoch-$n.json"); do
        echo "epoch $n: the electrode let through $x (no log of that core hub that day)"
        set -- "$@" --excuse "$x"
    done
    if ! "$NEON_ORACLE" "$@" "$work"; then
        rm -rf "$work"
        echo "epoch $n could not be computed here: not posted" >&2
        exit 1
    fi
    mine=$(jq -r .root "$work/epoch-$n.json")
    theirs=$(jq -r .root "$KEEP/epoch-$n.json")
    rm -rf "$work"
    if [ "$mine" != "$theirs" ]; then
        echo "epoch $n: computed here $mine, the electrode's $theirs: NOT posted (compare the inputs and the registry)" >&2
        exit 1
    fi
    echo "epoch $n computed here with the same root: $mine"
    tok post "$KEEP/epoch-$n.json" --previous "$prev"
    remote done "$n"
    file_local "$n"
done
