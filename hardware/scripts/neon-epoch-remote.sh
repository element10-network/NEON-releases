#!/bin/sh
# On the electrode that computes the epochs (eu1): the only thing the home poster's SSH key may run
# (owner 2026-11-03: the admin key stays at home; a Pi there posts each epoch). In
# ~ne/.ssh/authorized_keys, the poster's key as:
#   command="/opt/neon/neon-epoch-remote.sh",restrict ssh-ed25519 AAAA... neon-post
# It reads the request from SSH_ORIGINAL_COMMAND:
#   list      the epochs waiting in epochs/pending/ (one number a line)
#   get N     pending/epoch-N.json
#   prev N    epochs/epoch-(N-1).json (the one epoch N was computed from)
#   done N [H] pending/epoch-N.json moved into epochs/ (once its root is on chain); with H, only if
#             the file is still the one posted (H: sha256 of `jq -S -c .` of it; this electrode can
#             compute the epoch again and replace a pending file between the poster's get and done:
#             then the replaced one with that hash, kept in pending/replaced/, is filed instead)
#   scan      the newest world-scanner packets (scan-latest.json, written by neond every 30 s): the
#             vault's screen shows them (owner 2026-11-23; read only, public-channel packets only)
#   logs N    the signed day logs pending epoch N was computed from (its days and the day after,
#             this electrode's own, its mirrors' and the signatures seen), as a gzipped tar: the
#             poster computes the epoch again from them and posts only the same root (decision 5)
set -eu
# The request is split into words, never expanded as file names (a "*" in it stays a "*").
set -f
REPORTS=${REPORTS:-/var/lib/neon/reports}
EPOCHS=$REPORTS/epochs
set -- ${SSH_ORIGINAL_COMMAND:-}
what=${1:-}
n=${2:-}
case "$n" in
    "") [ "$what" = list ] || [ "$what" = scan ] || { echo "a number is needed" >&2; exit 2; } ;;
    *[!0-9]*) echo "not a number: $n" >&2; exit 2 ;;
esac
# The replaced versions of epoch N kept for `done` (file names expanded here only).
drop_replaced() {
    set +f
    rm -f "$EPOCHS/pending/replaced/epoch-$n-"*.json
    set -f
}
case "$what" in
    list)
        # File names expanded here only (`set -f` above switched them off for the request, and
        # with it this list: it always answered none, so hq never posted; owner 2026-11-17).
        set +f
        # (Not one filed already: a pending file left behind for it is stale, and listed it stopped
        # every later epoch, as `done` refuses it; review 2026-11-23.)
        for f in "$EPOCHS"/pending/epoch-*.json; do
            [ -e "$f" ] || continue
            f=${f##*/epoch-}
            f=${f%.json}
            [ -e "$EPOCHS/epoch-$f.json" ] && continue
            echo "$f"
        done | sort -n
        set -f
        ;;
    get) cat "$EPOCHS/pending/epoch-$n.json" ;;
    # (None yet, or an electrode without the world scanner: an empty list.)
    scan)
        [ -z "$n" ] || { echo "scan takes no number" >&2; exit 2; }
        # (None yet: an empty list; one that cannot be read is an error, not "nothing".)
        [ -e "$REPORTS/scan-latest.json" ] || { echo '{"items":[]}'; exit 0; }
        cat "$REPORTS/scan-latest.json"
        ;;
    prev)
        [ "$n" -gt 0 ] || { echo "epoch 0 has none" >&2; exit 2; }
        cat "$EPOCHS/epoch-$((n - 1)).json"
        ;;
    logs)
        f="$EPOCHS/pending/epoch-$n.json"
        [ -f "$f" ] || { echo "epoch $n is not pending" >&2; exit 1; }
        start=$(jq -r .start "$f")
        end=$(jq -r .end "$f")
        case "$start$end" in *[!0-9-]*) echo "not dates: $start $end" >&2; exit 1 ;; esac
        cd "$REPORTS"
        list=$(mktemp)
        trap 'rm -f "$list"' EXIT
        # From the day before the epoch: rules v16 read it too (a report stamped just after
        # midnight that reached a hub just before it), and the oracle requires the core hubs'.
        d=$(date -u -d "$start - 1 day" +%F)
        i=0
        # File names spelled out below (globbing is off for the request, on for these: the dates
        # are digits and dashes only).
        set +f
        while :; do
            for g in "reports-$d.jsonl" "reports-$d.sig.json" mirror/*/"reports-$d.jsonl" mirror/*/"reports-$d.sig.json"; do
                [ -f "$g" ] && echo "$g" >> "$list"
            done
            [ "$d" = "$end" ] && break
            i=$((i + 1))
            [ "$i" -le 9 ] || { echo "more than 9 days from the day before $start to $end" >&2; exit 1; }
            d=$(date -u -d "$d + 1 day" +%F)
        done
        set -f
        [ -d sigs ] && find sigs -type f >> "$list"
        tar czf - -T "$list"
        ;;
    done)
        want=${3:-}
        if [ -n "$want" ]; then
            case "$want" in *[!0-9a-f]*) echo "not a hash: $want" >&2; exit 2 ;; esac
            [ "${#want}" -eq 64 ] || { echo "not a hash: $want" >&2; exit 2; }
        fi
        f="$EPOCHS/pending/epoch-$n.json"
        # Filed already with the hash asked for (a run that filed it, then lost the answer): done,
        # and a pending file left for it since is stale (review 2026-11-23: it was refused for good).
        if [ -e "$EPOCHS/epoch-$n.json" ]; then
            if [ -n "$want" ] && [ "$(jq -S -c . "$EPOCHS/epoch-$n.json" | sha256sum | cut -c1-64)" = "$want" ]; then
                rm -f "$f"
                drop_replaced
                echo "epoch $n filed already"
                exit 0
            fi
            echo "epoch $n is filed already" >&2
            exit 1
        fi
        # Taken aside first, then checked (review 2026-11-16: an epoch computed again between the
        # check and the move would have been filed unposted); a mismatch goes back.
        [ -f "$f" ] || { echo "epoch $n is not pending" >&2; exit 1; }
        mv "$f" "$f.filing"
        if [ -n "$want" ]; then
            h=$(jq -S -c . "$f.filing" | sha256sum | cut -c1-64)
            if [ "$h" != "$want" ]; then
                [ -e "$f" ] || mv "$f.filing" "$f"
                rm -f "$f.filing"
                # The one posted was replaced since it was fetched (review 2026-11-23): that one,
                # kept by neon-epoch.sh, is filed; the newer pending file is then stale.
                r="$EPOCHS/pending/replaced/epoch-$n-$want.json"
                if [ -f "$r" ] && [ "$(jq -S -c . "$r" | sha256sum | cut -c1-64)" = "$want" ]; then
                    mv "$r" "$EPOCHS/epoch-$n.json"
                    rm -f "$f"
                    drop_replaced
                    echo "epoch $n filed (the result posted, replaced here since it was fetched)"
                    exit 0
                fi
                echo "epoch $n: the pending file changed since it was fetched (computed again): not filed" >&2
                exit 1
            fi
        fi
        mv "$f.filing" "$EPOCHS/epoch-$n.json"
        drop_replaced
        echo "epoch $n filed"
        ;;
    *) echo "list, scan, get N, prev N, logs N or done N" >&2; exit 2 ;;
esac
