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
# filed. The electrode lets this key do nothing else (neon-epoch-remote.sh; but read its world scanner's
# newest packets, `scan`, for the vault's screen).
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
# After each run (neon-post.service's ExecStopPost): when it ended and how, kept on disk, so the
# vault's Status and monitor show the last run after a restart too (systemd forgets it; owner
# 2026-11-19). "<Unix seconds> <result> <exit status>", the result as systemd gives it (success,
# exit-code, timeout...).
if [ "${1:-}" = --record-run ]; then
    f=/var/lib/neon-post/last-run
    # (75: another run held the lock, this one did nothing: not a run of its own, review 2026-11-19.)
    [ "${EXIT_STATUS:-}" = 75 ] && exit 0
    printf '%s %s %s\n' "$(date +%s)" "${SERVICE_RESULT:-unknown}" "${EXIT_STATUS:-?}" > "$f.tmp" && mv -f "$f.tmp" "$f"
    exit 0
fi
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
# One run at a time (the timer and one started by hand would both post the same epoch). Always the
# same lock, wherever KEEP is (review 2026-11-23: the vault's update takes this one; with KEEP set
# elsewhere an update could swap the programs in the middle of a run). Waited for up to 10 minutes
# (an update that holds it no longer costs the day's run); a run still going then: 75, nothing done.
LOCK=${NEON_POST_LOCK:-/var/lib/neon-post/epochs/.lock}
mkdir -p "${LOCK%/*}"
[ ! -L "$LOCK" ] || { echo "$LOCK is a link: nothing done" >&2; exit 1; }
exec 9>>"$LOCK"
flock -w 600 9 || { echo "already running"; exit 75; }

remote() {
    ssh -i "$SSH_KEY" -p "$PORT" -o BatchMode=yes -o ConnectTimeout=30 \
        -o UserKnownHostsFile=/var/lib/neon-post/ssh/known_hosts "$REMOTE" "$@"
}
# The hub history neon-token read before, kept by systemd (CacheDirectory=): only what is new is read.
[ -n "${CACHE_DIRECTORY:-}" ] && export NEON_TOKEN_CACHE="${NEON_TOKEN_CACHE:-$CACHE_DIRECTORY}"
tok() { "$NEON_TOKEN" --url "$URL" --keypair "$KEYPAIR" "$@"; }
# The same JSON whatever the key order or spacing (review 2026-11-16: compared byte for byte, a
# difference in writing alone would stop every following epoch).
same_json() { [ "$(jq -S -c . "$1" 2>/dev/null)" = "$(jq -S -c . "$2" 2>/dev/null)" ] && [ -n "$(jq -c . "$1" 2>/dev/null)" ]; }
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

# A kept epoch whose root the chain says is not there or another one (the guardian cancelled it and
# it was posted again): set aside to cancelled/. Only on the chain's word, as neon-epoch.sh moves
# its own (review 2026-11-19: an RPC error was taken as "cancelled"); an RPC that does not answer
# leaves it where it is.
set_aside_cancelled() {
    f="$KEEP/epoch-$1.json"
    [ -s "$f" ] || return 0
    chk=$(tok check "$f" 2>&1 || true)
    case "$chk" in
        *"has no root on chain"* | *"is not the one on chain"*)
            mkdir -p "$KEEP/cancelled"
            mv "$f" "$KEEP/cancelled/epoch-$1.json.$(date -u +%Y%m%dT%H%M%SZ)"
            echo "epoch $1: the one kept here is not the root on chain (cancelled and posted again): moved to $KEEP/cancelled/" >&2
            ;;
    esac
}

waiting=$(remote list)
[ -n "$waiting" ] || { echo "no epoch waiting"; exit 0; }
for n in $waiting; do
    case "$n" in "" | *[!0-9]*) echo "not an epoch number from the electrode: $n" >&2; exit 1 ;; esac
    next=$(tok next-epoch)
    # A number, or nothing is decided from it (a failed test would read as "no" and post).
    case "$next" in "" | *[!0-9]*) echo "next-epoch gave '$next', not a number: nothing done" >&2; exit 1 ;; esac
    if [ "$n" -lt "$next" ]; then
        echo "epoch $n is on chain already: filing it"
        # Posted from here and kept, but its "done" never reached the electrode (a dropped SSH),
        # which may have computed the epoch again since: this machine's own file, if its root is
        # the one on chain, is filed by its hash (the electrode keeps a replaced copy for that);
        # else the electrode's (review 2026-11-23: its newer file failed the check every day and
        # both machines stayed stuck).
        # (Filed here first: its root is on chain, and an answer lost on the way back must not
        # leave it unfiled here, review 2026-11-23.)
        if [ -s "$KEEP/epoch-$n.json" ] && tok check "$KEEP/epoch-$n.json" >/dev/null 2>&1; then
            file_local "$n"
            if remote done "$n" "$(jq -S -c . "$KEEP/epoch-$n.json" | sha256sum | cut -c1-64)"; then
                continue
            fi
            kept_on_chain=1
        else
            kept_on_chain=
        fi
        # The electrode's copy, not one kept here: posted by hand, or kept from a run whose post
        # failed before the electrode computed it again, this one may be missing or another.
        remote get "$n" > "$KEEP/epoch-$n.json.part"
        # Only the one whose root is on chain (another would show "does not match the posted
        # root" on every claim page, and epoch n+1's post would refuse it as its previous).
        if ! tok check "$KEEP/epoch-$n.json.part"; then
            rm -f "$KEEP/epoch-$n.json.part"
            if [ -n "$kept_on_chain" ]; then
                echo "epoch $n: this machine's file ($KEEP/epoch-$n.json) is the one on chain, but the electrode could not file it and its own differs: copy this machine's file to the electrode's epochs/ by hand" >&2
                exit 1
            fi
            echo "epoch $n: not filed: its file could not be matched with the root on chain (the reason above; a NEON-token CLI older than bd12b03 has no 'check': rebuild it)" >&2
            exit 1
        fi
        # One kept here whose root is not the one on chain was cancelled by the guardian and the
        # epoch posted again since (review 2026-11-19: it was refused on every run, epoch n+1 stuck):
        # moved aside, the electrode's file (checked above) taken instead.
        set_aside_cancelled "$n"
        # Kept here already (posted from here): the electrode's copy must be that same file. It
        # carries what the root does not cover (wallets named, amounts held, onboarded hotspots,
        # core hubs, the hardware rule) and becomes the next epoch's previous (review 2026-11-13).
        if [ -s "$KEEP/epoch-$n.json" ]; then
            if ! same_json "$KEEP/epoch-$n.json" "$KEEP/epoch-$n.json.part"; then
                rm -f "$KEEP/epoch-$n.json.part"
                echo "epoch $n: the electrode's file differs from the one posted from here ($KEEP/epoch-$n.json): not filed (copy this machine's file to the electrode's epochs/ by hand)" >&2
                exit 1
            fi
            rm -f "$KEEP/epoch-$n.json.part"
        else
            # Posted by hand elsewhere: the electrode's word on what the root does not cover.
            echo "epoch $n: none kept here, the electrode's file taken (its onboarded hotspots are all looked up on Helium with the next epoch)" >&2
            # Marked before it is kept (review 2026-11-16: a stop between the two kept it unmarked).
            : > "$KEEP/epoch-$n.json.from-electrode"
            mv "$KEEP/epoch-$n.json.part" "$KEEP/epoch-$n.json"
        fi
        remote done "$n" "$(jq -S -c . "$KEEP/epoch-$n.json" | sha256sum | cut -c1-64)"
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
    # (One kept here that the guardian cancelled, epoch n-1 posted again elsewhere: set aside.)
    if [ -s "$KEEP/epoch-$((n - 1)).json" ] && ! same_json "$KEEP/epoch-$((n - 1)).json" "$KEEP/epoch-$((n - 1)).json.part"; then
        set_aside_cancelled "$((n - 1))"
    fi
    if [ -s "$KEEP/epoch-$((n - 1)).json" ] && ! same_json "$KEEP/epoch-$((n - 1)).json" "$KEEP/epoch-$((n - 1)).json.part"; then
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
    # Still the electrode's word at the next run if this one stops before posting (review
    # 2026-11-16: kept without the mark, it was trusted then); marked before it is kept.
    if [ "$audit_all" = 1 ]; then : > "$KEEP/epoch-$((n - 1)).json.from-electrode"; fi
    mv "$KEEP/epoch-$((n - 1)).json.part" "$KEEP/epoch-$((n - 1)).json"
    # The previous result must be the one on chain (checked against its posted root).
    tok check "$KEEP/epoch-$((n - 1)).json" || { echo "epoch $((n - 1)) does not match the root on chain: epoch $n not posted" >&2; exit 1; }
    # Computed again here from the signed logs, with the registry from the chain, the previous
    # epoch's hardware rule, and the electrode's core hubs, onboarded list and excused days (each
    # recorded in its result, shown here).
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    # Unpacked into a directory of their own, apart from this script's own files (review 2026-11-23:
    # a link in the electrode's tar named like one of them, theirs.sorted say, had them written
    # through it, into the hub history's cache or the kept epochs). Plain files and directories only.
    mkdir "$work/logs"
    remote logs "$n" | tar xzf - --no-same-owner --no-same-permissions -C "$work/logs" ||
        { echo "epoch $n: its day logs could not be fetched: not posted" >&2; exit 1; }
    odd=$(find "$work/logs" ! -type f ! -type d | head -n 3)
    [ -z "$odd" ] || { echo "epoch $n: the electrode's logs hold something other than files and directories ($odd): not posted" >&2; exit 1; }
    # The registry as the chain has it now: a hub registered (or a wallet changed) since the
    # electrode's run gives another root, and the epoch waits (compute it again on the electrode).
    prev="$KEEP/epoch-$((n - 1)).json"
    # With its history, as the electrode's run takes it (each day's registry from 2026-11-30).
    # The admin's requests from the epoch's start less 38 days, as the electrode reads them (review
    # 2026-11-16: the same days whenever each runs). A neon-token without --since: its own window.
    since=$(date -u -d "$(jq -r .start "$theirs_file") - 38 days" +%F)
    if "$NEON_TOKEN" --help 2>/dev/null | grep -q -- '--since'; then
        tok hubs --history --since "$since" "$prev" > "$work/hubs.json"
    else
        tok hubs --history "$prev" > "$work/hubs.json"
    fi
    jq -e 'has("changes")' "$work/hubs.json" >/dev/null ||
        { echo "epoch $n: neon-token printed no registry history (older than NEON-token 1f07919: update it): not posted" >&2; exit 1; }
    # What decides whom the computation trusts is not taken from the electrode alone (review
    # 2026-11-11: a compromised electrode could drop the core hubs, excuse their days, or add
    # hotspots): the core hubs are the previous posted epoch's, or the new list named in post.conf.
    theirs_core=$(jq -r '.core_hubs // [] | sort | join(" ")' "$theirs_file")
    prev_core=$(jq -r '.core_hubs // [] | sort | join(" ")' "$prev")
    # In code-point order, as jq sorts (a locale's order puts 12D3KooWa... before 12D3KooWB...).
    conf_core=$(printf '%s\n' $CORE_HUBS | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')
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
    # Checked as the electrode checks them (neon-epoch.sh): numbers, one per wallet and epoch.
    mine_cb="" wallets=" "
    # (The same checks as neon-epoch.sh's: change both together; eu1 and hq must refuse the same entries.)
    for x in $CLAWBACK; do
        case "$x" in
            *[!0-9A-Za-z:]* | *:*:*:* | :* | *: | *::*) echo "CLAWBACK in $CONF: $x is not N:<wallet>:<amount>" >&2; exit 1 ;;
            [0-9]*:*:[1-9]*) ;;
            *) echo "CLAWBACK in $CONF: $x is not N:<wallet>:<amount> (the amount above 0)" >&2; exit 1 ;;
        esac
        e=${x%%:*} rest=${x#*:}
        w=${rest%%:*} a=${rest#*:}
        case "$e$a" in *[!0-9]*) echo "CLAWBACK in $CONF: $x: the epoch and the amount are numbers" >&2; exit 1 ;; esac
        # No leading zeros (01 would pass as text and never equal the epoch: lost, not refused).
        case "$e" in 0?*) echo "CLAWBACK in $CONF: $x: the epoch without leading zeros" >&2; exit 1 ;; esac
        [ "$e" = "$n" ] || continue
        case "$wallets" in *" $w "*) echo "CLAWBACK in $CONF: $w named twice for epoch $n" >&2; exit 1 ;; esac
        wallets="$wallets$w "
        mine_cb="$mine_cb $x"
    done
    mine_cb=$(printf '%s\n' $mine_cb | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')
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
    if ! "$NEON_ORACLE" "$@" "$work/logs"; then
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
    remote done "$n" "$(jq -S -c . "$KEEP/epoch-$n.json" | sha256sum | cut -c1-64)"
    file_local "$n"
done
