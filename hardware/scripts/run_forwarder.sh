#!/bin/sh
# Run the packet forwarder in the foreground, with live output saved to a log.
#
# install.sh copies this to /opt/neon/<chip>/run.sh. Usage:
#   sudo /opt/neon/sx1302/run.sh            # refuses if something else is using the radio
#   sudo /opt/neon/sx1302/run.sh --force    # stops other forwarders / Semtech test tools first
#
# Logs go to /opt/neon/<chip>/logs/, with logs/latest.log pointing at the newest one.

set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
cd "$DIR"

# Only one program may drive the concentrator at a time.
busy() {
    pgrep -x lora_pkt_fwd >/dev/null 2>&1 || pgrep -f 'test_loragw_' >/dev/null 2>&1
}
if command -v systemctl >/dev/null && systemctl is-active --quiet neon-forwarder 2>/dev/null; then
    echo "neon-forwarder.service is running. Stop it first: sudo systemctl stop neon-forwarder" >&2
    exit 1
fi
if busy; then
    echo "Another program is using the radio:" >&2
    pgrep -a -x lora_pkt_fwd >&2 || true
    pgrep -a -f 'test_loragw_' >&2 || true
    if [ "${1:-}" != "--force" ]; then
        echo "Stop it first, or run: sudo $0 --force" >&2
        exit 1
    fi
    pkill -x lora_pkt_fwd || true
    pkill -f 'test_loragw_' || true
    sleep 1
    if busy; then
        echo "Could not stop it." >&2
        exit 1
    fi
fi

# The SX1302 forwarder resets the chip itself; the SX1301 one does not.
case "$DIR" in
    */sx1301) ./reset_lgw.sh start ;;
esac

mkdir -p logs
LOG="$DIR/logs/fwd-$(date +%Y%m%d-%H%M%S).log"
ln -sf "$LOG" logs/latest.log
echo "Logging to $LOG (Ctrl+C to stop)"

# stdbuf: line-buffered output, so status blocks appear as they happen even through tee.
stdbuf -oL -eL ./lora_pkt_fwd 2>&1 | tee "$LOG"
