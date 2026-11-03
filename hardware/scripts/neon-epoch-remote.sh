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
set -eu
EPOCHS=${REPORTS:-/var/lib/neon/reports}/epochs
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
    done)
        [ -e "$EPOCHS/epoch-$n.json" ] && { echo "epoch $n is filed already" >&2; exit 1; }
        mv "$EPOCHS/pending/epoch-$n.json" "$EPOCHS/epoch-$n.json"
        echo "epoch $n filed"
        ;;
    *) echo "list, get N, prev N or done N" >&2; exit 2 ;;
esac
