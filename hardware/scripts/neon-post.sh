#!/bin/sh
# Posts each epoch's root from home (owner 2026-11-03: the admin key stays at home; the electrode
# computes the epoch at 02:30 UTC on Tuesdays into epochs/pending/). Run daily by neon-post.timer
# on a Pi at home; nothing to do on other days.
#
# For every epoch waiting on the electrode, in order: fetch it and the one it was computed from,
# check with the chain what comes next (neon-token next-epoch), post it with the admin key
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
set -eu
CONF=${NEON_POST_CONF:-/etc/neon/post.conf}
[ -f "$CONF" ] || { echo "no settings: $CONF"; exit 1; }
. "$CONF"
: "${NEON_TOKEN:?}" "${KEYPAIR:?}" "${REMOTE:?}" "${SSH_KEY:?}"
URL=${URL:-devnet}
PORT=${PORT:-22}
KEEP=${KEEP:-/var/lib/neon-post/epochs}
mkdir -p "$KEEP"

remote() {
    ssh -i "$SSH_KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=30 \
        -o UserKnownHostsFile=/var/lib/neon-post/ssh/known_hosts "$REMOTE" "$@"
}
tok() { "$NEON_TOKEN" --url "$URL" --keypair "$KEYPAIR" "$@"; }

waiting=$(remote list)
[ -n "$waiting" ] || { echo "no epoch waiting"; exit 0; }
for n in $waiting; do
    next=$(tok next-epoch)
    if [ "$n" -lt "$next" ]; then
        echo "epoch $n is on chain already: filing it"
        remote done "$n"
        continue
    fi
    if [ "$n" -gt "$next" ]; then
        echo "epoch $n waits for epoch $next, which is not on chain: not posted" >&2
        exit 1
    fi
    remote get "$n" > "$KEEP/epoch-$n.json.part"
    mv "$KEEP/epoch-$n.json.part" "$KEEP/epoch-$n.json"
    if [ "$n" -gt 0 ]; then
        remote prev "$n" > "$KEEP/epoch-$((n - 1)).json.part"
        mv "$KEEP/epoch-$((n - 1)).json.part" "$KEEP/epoch-$((n - 1)).json"
        tok post "$KEEP/epoch-$n.json" --previous "$KEEP/epoch-$((n - 1)).json"
    else
        tok post "$KEEP/epoch-$n.json"
    fi
    remote done "$n"
done
