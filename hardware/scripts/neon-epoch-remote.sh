#!/bin/sh
# On the electrode that computes the epochs (eu1): the only thing the home poster's SSH key may run
# (owner 2026-11-03: the admin key stays at home; a Pi there posts each epoch). In
# ~ne/.ssh/authorized_keys, the poster's key as:
#   command="/opt/neon/neon-epoch-remote.sh",restrict ssh-ed25519 AAAA... neon-post
# It reads the request from SSH_ORIGINAL_COMMAND:
#   list      the epochs waiting in epochs/pending/ (one number a line)
#   get N     pending/epoch-N.json
#   prev N    epochs/epoch-(N-1).json (the one epoch N was computed from)
#   done N    pending/epoch-N.json moved into epochs/ (once its root is on chain)
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
    "") [ "$what" = list ] || { echo "a number is needed" >&2; exit 2; } ;;
    *[!0-9]*) echo "not a number: $n" >&2; exit 2 ;;
esac
case "$what" in
    list)
        for f in "$EPOCHS"/pending/epoch-*.json; do
            [ -e "$f" ] || continue
            f=${f##*/epoch-}
            echo "${f%.json}"
        done | sort -n
        ;;
    get) cat "$EPOCHS/pending/epoch-$n.json" ;;
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
        [ -e "$EPOCHS/epoch-$n.json" ] && { echo "epoch $n is filed already" >&2; exit 1; }
        mv "$EPOCHS/pending/epoch-$n.json" "$EPOCHS/epoch-$n.json"
        echo "epoch $n filed"
        ;;
    *) echo "list, get N, prev N, logs N or done N" >&2; exit 2 ;;
esac
