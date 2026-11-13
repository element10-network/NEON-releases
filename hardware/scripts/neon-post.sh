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
#   CORE_HUBS="<peer id> <peer id>"   only when the core electrodes change: the new list (each epoch
#                                     takes the previous posted epoch's; a change the electrode
#                                     asks for is refused unless named here)
#   EXCUSE="2026-11-17:<peer id> ..."  days of a core electrode let through without its log: only
#                                     these (the electrode's word alone is not taken)
#   CLAWBACK="N:<wallet>:<amount> ..."  over-claims recorded with epoch N (smallest units, owed back
#                                     from the wallet's later earnings): only these, as the
#                                     electrode's epoch.conf names them
#   HELIUM_RPC=https://api.mainnet-beta.solana.com   where each newly onboarded hotspot is looked up
#   LOCAL_EPOCHS=/var/lib/neon/reports/epochs   an electrode on this machine too: it gets each
#                                              posted epoch, so its own claim answers stay current
#                                              (default: this directory, when it exists; this
#                                              user must be able to write it: sudo chown -R ne: it)
set -eu
CONF=${NEON_POST_CONF:-/etc/neon/post.conf}
[ -f "$CONF" ] || { echo "no settings: $CONF"; exit 1; }
. "$CONF"
: "${NEON_TOKEN:?}" "${KEYPAIR:?}" "${REMOTE:?}" "${SSH_KEY:?}"
CORE_HUBS=${CORE_HUBS:-}
EXCUSE=${EXCUSE:-}
CLAWBACK=${CLAWBACK:-}
HELIUM_RPC=${HELIUM_RPC:-https://api.mainnet-beta.solana.com}
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
        # Kept here already (posted from here): the electrode's copy must be that same file. It
        # carries what the root does not cover (wallets named, amounts held, onboarded hotspots,
        # core hubs, the hardware rule) and becomes the next epoch's previous (review 2026-11-13).
        if [ -s "$KEEP/epoch-$n.json" ]; then
            if ! cmp -s "$KEEP/epoch-$n.json" "$KEEP/epoch-$n.json.part"; then
                rm -f "$KEEP/epoch-$n.json.part"
                echo "epoch $n: the electrode's file differs from the one posted from here ($KEEP/epoch-$n.json): not filed (copy this machine's file to the electrode's epochs/ by hand)" >&2
                exit 1
            fi
            rm -f "$KEEP/epoch-$n.json.part"
        else
            # Posted by hand elsewhere: the electrode's word on what the root does not cover.
            echo "epoch $n: none kept here, the electrode's file taken (its onboarded hotspots are all looked up on Helium with the next epoch)" >&2
            mv "$KEEP/epoch-$n.json.part" "$KEEP/epoch-$n.json"
            : > "$KEEP/epoch-$n.json.from-electrode"
        fi
        remote done "$n"
        file_local "$n"
        continue
    fi
    if [ "$n" -gt "$next" ]; then
        echo "epoch $n waits for epoch $next, which is not on chain: not posted" >&2
        exit 1
    fi
    # The electrode's result, apart from what is kept here (only this machine's own result,
    # computed below, is kept as epoch-N.json).
    theirs_file="$KEEP/epoch-$n.electrode.json"
    remote get "$n" > "$theirs_file.part"
    mv "$theirs_file.part" "$theirs_file"
    [ "$n" -gt 0 ] || { echo "epoch 0 is not computed again here (genesis): post it by hand" >&2; exit 1; }
    remote prev "$n" > "$KEEP/epoch-$((n - 1)).json.part"
    # The previous result as this machine kept it when it posted it (it carries state the root
    # does not cover: wallets named before, amounts held, onboarded hotspots, earlier roots): the
    # electrode's copy must be the same file.
    if [ -s "$KEEP/epoch-$((n - 1)).json" ] && ! cmp -s "$KEEP/epoch-$((n - 1)).json" "$KEEP/epoch-$((n - 1)).json.part"; then
        echo "epoch $((n - 1)) on the electrode differs from the one posted from here: epoch $n not posted" >&2
        exit 1
    fi
    # None kept here (or one taken from the electrode): its carried state is the electrode's word,
    # so every onboarded hotspot in it is looked up below, not only the new ones.
    audit_all=0
    if [ ! -s "$KEEP/epoch-$((n - 1)).json" ] || [ -e "$KEEP/epoch-$((n - 1)).json.from-electrode" ]; then
        audit_all=1
        echo "epoch $n: epoch $((n - 1)) was not computed here: its onboarded hotspots are all looked up on Helium" >&2
    fi
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
    # What decides whom the computation trusts is not taken from the electrode alone (review
    # 2026-11-11: a compromised electrode could drop the core hubs, excuse their days, or add
    # hotspots): the core hubs are the previous posted epoch's, or the new list named in post.conf.
    theirs_core=$(jq -r '.core_hubs // [] | sort | join(" ")' "$theirs_file")
    prev_core=$(jq -r '.core_hubs // [] | sort | join(" ")' "$prev")
    conf_core=$(printf '%s\n' $CORE_HUBS | sort | tr '\n' ' ' | sed 's/ $//')
    # A previous epoch taken from the electrode (none computed here) is the electrode's word on
    # what it carries: it must name core hubs (or CORE_HUBS in post.conf names them), and the
    # hardware rule (in force since before epoch 0), or a compromised electrode could drop both.
    if [ "$audit_all" = 1 ]; then
        [ -n "$prev_core" ] || [ -n "$conf_core" ] ||
            { echo "epoch $n: epoch $((n - 1)) came from the electrode and names no core hubs: name them in CORE_HUBS in $CONF; not posted" >&2; exit 1; }
        [ -n "$(jq -r '.hardware_from // ""' "$prev")" ] ||
            { echo "epoch $n: epoch $((n - 1)) came from the electrode without the hardware rule: not posted" >&2; exit 1; }
        if [ -z "$prev_core" ]; then prev_core=$conf_core; fi
    fi
    # A result naming no core hubs would make every electrode's log count on its own (review
    # 2026-11-13): refused, whatever the previous epoch named.
    [ -n "$theirs_core" ] || { echo "epoch $n: the electrode's result names no core hubs: not posted" >&2; exit 1; }
    # A previous epoch from before core hubs were recorded: the electrode's list, once (shown).
    if [ -z "$prev_core" ]; then
        echo "epoch $n: epoch $((n - 1)) names no core hubs: the electrode's list taken"
    elif [ "$theirs_core" != "$prev_core" ] && [ "$theirs_core" != "$conf_core" ]; then
        echo "epoch $n: the electrode's core hubs ($theirs_core) are not epoch $((n - 1))'s ($prev_core): not posted (if the change is right, name the new list in CORE_HUBS in $CONF)" >&2
        exit 1
    fi
    set -- --launch "$(jq -r .launch "$prev")" --treasury "$TREASURY" --epoch "$n" \
        --previous "$prev" --hubs "$work/hubs.json" --core-hubs "$theirs_file" --out "$work/epoch-$n.json"
    echo "epoch $n: core hubs $theirs_core"
    from=$(jq -r '.hardware_from // ""' "$prev")
    if [ -n "$from" ]; then
        set -- "$@" --hardware-from "$from" --onboarded "$theirs_file"
        # Each hotspot the electrode added since the previous epoch, looked up on Helium (its
        # onboarding account on Solana mainnet) from here too (owner 2026-11-12): the electrode's
        # word alone does not let a chip earn. No answer: not posted (try again later).
        added=0
        # Base58 addresses only (anything else stops the post); the new ones, or all of them when the
        # previous epoch is the electrode's word. With globbing off: they come from the electrode.
        set -f
        if [ "$audit_all" = 1 ]; then which='(.onboarded // [])'; else which='(.onboarded // []) - ($p[0].onboarded // [])'; fi
        list=$(jq -e -r --slurpfile p "$prev" "$which"' | if all(.[]; type == "string" and test("^[1-9A-HJ-NP-Za-km-z]{20,64}$")) then .[] else error("not a Helium address") end' "$theirs_file") ||
            { [ $? -eq 4 ] || { echo "epoch $n: the electrode's onboarded list is not a list of Helium addresses: not posted" >&2; exit 1; }; }
        for h in $list; do
            acct=$("$NEON_ORACLE" --onboarding-account "$h") || { echo "epoch $n: $h is not a Helium address: not posted" >&2; exit 1; }
            owner=error
            # A public RPC limits each address: a few tries, a pause between hotspots.
            for try in 1 2 3; do
                resp=$(curl -fsS -m 30 "$HELIUM_RPC" -H 'Content-Type: application/json' \
                    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getAccountInfo\",\"params\":[\"${acct% *}\",{\"encoding\":\"base64\",\"dataSlice\":{\"offset\":0,\"length\":0}}]}") || resp=""
                owner=$(printf '%s' "$resp" | jq -r 'if (.result | type) == "object" then (.result.value.owner // "none") else "error" end' 2>/dev/null) || owner=error
                [ -n "$owner" ] || owner=error
                [ "$owner" = error ] || break
                sleep $((try * 5))
            done
            case "$owner" in
                "${acct#* }") added=$((added + 1)) ;;
                error) echo "epoch $n: Helium's onboarding of $h could not be looked up ($HELIUM_RPC): not posted (try again later)" >&2; exit 1 ;;
                *) echo "epoch $n: the electrode lists $h as onboarded, but Helium does not: not posted" >&2; exit 1 ;;
            esac
            sleep 1
        done
        set +f
        echo "epoch $n: $added hotspot(s) looked up on Helium from here, each onboarded"
    fi
    set -f
    for x in $(jq -r '.excused // [] | .[]' "$theirs_file"); do
        case " $EXCUSE " in
            *" $x "*) ;;
            *) echo "epoch $n: the electrode let through $x (no log of that core hub that day), not named in EXCUSE in $CONF: not posted" >&2; exit 1 ;;
        esac
        echo "epoch $n: let through $x (no log of that core hub that day; EXCUSE in $CONF)"
        set -- "$@" --excuse "$x"
    done
    # Over-claims: only those named in post.conf, and exactly the electrode's (the same input).
    theirs_cb=$(jq -r '(.clawback // {}) | to_entries | map("'"$n"':\(.key):\(.value|tostring)") | sort | join(" ")' "$theirs_file")
    # Exactly the ones named here for this epoch, both ways (one left out by the electrode would
    # be lost for good: it is recorded with its epoch only). Each N:<wallet>:<amount>.
    mine_cb=""
    for x in $CLAWBACK; do
        case "$x" in
            *[!0-9A-Za-z:]* | *:*:*:* | :* | *: | *::*) echo "CLAWBACK in $CONF: $x is not N:<wallet>:<amount>" >&2; exit 1 ;;
            [0-9]*:*:[1-9]*) ;;
            *) echo "CLAWBACK in $CONF: $x is not N:<wallet>:<amount> (the amount above 0)" >&2; exit 1 ;;
        esac
        case "$x" in "$n":*) mine_cb="$mine_cb $x" ;; esac
    done
    mine_cb=$(printf '%s\n' $mine_cb | sort | tr '\n' ' ' | sed 's/ *$//')
    if [ "$mine_cb" != "$theirs_cb" ]; then
        echo "epoch $n: the electrode recorded the over-claims [$theirs_cb], CLAWBACK in $CONF names [$mine_cb] for it: not posted" >&2
        exit 1
    fi
    for x in $theirs_cb; do echo "epoch $n: over-claim $x recorded (CLAWBACK in $CONF)"; done
    set +f
    if [ -n "$theirs_cb" ]; then
        jq '.clawback' "$theirs_file" > "$work/clawback.json"
        set -- "$@" --clawback "$work/clawback.json"
    fi
    if ! "$NEON_ORACLE" "$@" "$work"; then
        rm -rf "$work"
        echo "epoch $n could not be computed here: not posted" >&2
        exit 1
    fi
    mine=$(jq -r .root "$work/epoch-$n.json")
    theirs=$(jq -r .root "$theirs_file")
    if [ "$mine" != "$theirs" ]; then
        rm -rf "$work"
        echo "epoch $n: computed here $mine, the electrode's $theirs: NOT posted (compare the inputs and the registry)" >&2
        exit 1
    fi
    # The whole result, not only the root (review 2026-11-12): the wallets named, the amounts held,
    # the earlier roots and the onboarded list are carried to the next epoch and the root does not
    # cover them. This machine's own result is the one posted and kept; the electrode's must be the
    # same (computed from the same inputs, nothing in it depends on where it ran).
    jq -S . "$work/epoch-$n.json" > "$work/mine.sorted"
    jq -S . "$theirs_file" > "$work/theirs.sorted"
    if ! cmp -s "$work/mine.sorted" "$work/theirs.sorted"; then
        diff "$work/mine.sorted" "$work/theirs.sorted" | head -n 20 >&2
        rm -rf "$work"
        echo "epoch $n: the same root, but the electrode's result differs from this machine's in what it carries to the next epoch (above): NOT posted" >&2
        exit 1
    fi
    mv "$work/epoch-$n.json" "$KEEP/epoch-$n.json"
    rm -f "$theirs_file" "$KEEP/epoch-$n.json.from-electrode"
    rm -rf "$work"
    echo "epoch $n computed here with the same root and the same result: $mine"
    tok post "$KEEP/epoch-$n.json" --previous "$prev"
    remote done "$n"
    file_local "$n"
done
