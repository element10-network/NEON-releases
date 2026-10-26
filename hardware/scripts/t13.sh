#!/bin/sh
# T13 long run: collect what the next session needs from a station or hub.
#
#   hardware/scripts/t13.sh start    right after installing the build: notes the start and
#                                    samples neond's memory every hour (crontab); refuses while
#                                    a run is going (start --new throws that run away)
#   hardware/scripts/t13.sh report   at the end: prints the report, saves it to
#                                    ~/neon-t13/report-HOST.txt and stops the hourly sampling
#
# Works for the station service (neond) and the hub service (neon-hub). Uses sudo for the journal.
set -eu

DIR="$HOME/neon-t13"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="$(hostname)"

unit() {
    for u in neond neon-hub; do
        if systemctl is-active --quiet "$u"; then echo "$u"; return; fi
    done
    echo neond
}

rss_kb() { ps -o rss= -C neond | awk '{s += $1} END {print s + 0}'; }

case "${1:-}" in
start)
    mkdir -p "$DIR"
    # Do not throw away a run in progress (started, and not yet reported).
    if [ -f "$DIR/started" ] && [ ! -f "$DIR/report-$HOST.txt" -o "$DIR/started" -nt "$DIR/report-$HOST.txt" ] \
        && [ "${2:-}" != "--new" ]; then
        echo "A T13 run is already going since $(cat "$DIR/started")." >&2
        echo "Run '$SELF report' first, or '$SELF start --new' to throw it away and start again." >&2
        exit 1
    fi
    date -u '+%Y-%m-%d %H:%M:%S UTC' > "$DIR/started"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $(rss_kb)" > "$DIR/rss.log"
    if command -v crontab >/dev/null; then
        (crontab -l 2>/dev/null | grep -v 'neon-t13-sample' || true; echo "7 * * * * $SELF sample # neon-t13-sample") | crontab -
    else
        echo "No crontab here: memory is only measured at the start and in the report."
    fi
    echo "T13 started on $HOST ($(unit)), $(git -C "$REPO" log --oneline -1 2>/dev/null)."
    echo "Memory is sampled every hour into $DIR/rss.log. Run '$SELF report' at the end."
    ;;
sample)
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $(rss_kb)" >> "$DIR/rss.log"
    ;;
report)
    U="$(unit)"
    SINCE="$(cat "$DIR/started" 2>/dev/null || echo '3 days ago')"
    OUT="$DIR/report-$HOST.txt"
    mkdir -p "$DIR"
    {
        echo "=== T13 report: $HOST, unit $U, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "build: $(git -C "$REPO" log --oneline -1 2>/dev/null)"
        echo "started: $SINCE"
        echo
        echo "=== service"
        systemctl show "$U" -p ActiveEnterTimestamp -p NRestarts -p Result
        echo
        echo "=== memory (UTC time, RSS in kB), first and last samples"
        head -3 "$DIR/rss.log" 2>/dev/null; echo "..."; tail -3 "$DIR/rss.log" 2>/dev/null
        echo "now: $(rss_kb) kB"
        echo
        echo "=== starts and exits"
        sudo journalctl -u "$U" --since "$SINCE" --no-pager -o short-iso \
            | grep -E 'Started|Stopped|exited|panicked|restarting' | tail -20 || true
        echo
        echo "=== warnings and errors: count by message"
        sudo journalctl -u "$U" --since "$SINCE" --no-pager -o cat \
            | sed 's/\x1b\[[0-9;]*m//g' | grep -E ' (WARN|ERROR) ' \
            | sed -E 's/^[^ ]+ +(WARN|ERROR) +([^ ]+) (.*)$/\1 \2 \3/' \
            | sed -E 's/ [a-z_]+=[^ ]+//g' | sort | uniq -c | sort -rn | head -30 || true
        echo
        echo "=== warnings and errors: last 30"
        sudo journalctl -u "$U" --since "$SINCE" --no-pager -o short-iso \
            | sed 's/\x1b\[[0-9;]*m//g' | grep -E ' (WARN|ERROR) ' | tail -30 || true
        echo
        echo "=== last summary lines"
        sudo journalctl -u "$U" --since "$SINCE" --no-pager -o short-iso \
            | sed 's/\x1b\[[0-9;]*m//g' | grep ' summary' | tail -3 || true
        PID="$(pgrep -x neond | head -1 || true)"
        RDIR="$( [ -n "$PID" ] && tr '\0' '\n' < "/proc/$PID/cmdline" | sed -n '/^--reports-dir$/{n;p;}; s/^--reports-dir=//p' | head -1 || true)"
        if [ -n "$RDIR" ]; then
            POINTS="$(command -v neon-points || echo "$REPO/target/release/neon-points")"
            echo
            echo "=== points (hub, $RDIR)"
            for f in $(ls "$RDIR"/reports-*.jsonl 2>/dev/null | tail -4); do
                echo "--- $f"; "$POINTS" "$f" 2>&1 | tail -15
            done
        fi
    } > "$OUT" 2>&1
    if command -v crontab >/dev/null; then
        (crontab -l 2>/dev/null | grep -v 'neon-t13-sample' || true) | crontab -
    fi
    cat "$OUT"
    echo
    echo "Saved to $OUT. Paste it into the Neon session."
    ;;
*)
    echo "usage: $0 start|report" >&2
    exit 2
    ;;
esac
