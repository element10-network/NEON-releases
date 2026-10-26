#!/bin/sh
# Run by systemd before each neond start (ExecStartPre). After an update from the
# panel, neond leaves /opt/neon/update.json until the new binary is healthy (the packet
# forwarder heard, or no radio configured, and the web panel serving) or has run for ten
# minutes. A crash or exit before that puts the previous binary back at the next start.
# A deliberate stop (panel restart, systemctl, reboot) leaves update.alive, and a power cut
# changes the boot ID (kept in update.boot): such a start is not counted as a failure.
STATE=${NEON_STATE_DIR:-/opt/neon}
# A state directory changed in the panel (neond.toml) is where neond writes update.json.
if [ -z "${NEON_STATE_DIR:-}" ] && [ -f /opt/neon/neond.toml ]; then
    d=$(sed -n 's/^state_dir *= *"\(.*\)"$/\1/p' /opt/neon/neond.toml | head -n 1)
    [ -n "$d" ] && [ -d "$d" ] && STATE=$d
fi
# --state-dir on the command line (NEOND_ARGS, from the unit's environment file) wins.
case " ${NEOND_ARGS:-} " in
    *" --state-dir="*) d=$(printf ' %s ' "$NEOND_ARGS" | sed -n 's/.* --state-dir=\([^ ]*\) .*/\1/p');;
    *" --state-dir "*) d=$(printf ' %s ' "$NEOND_ARGS" | sed -n 's/.* --state-dir \([^ ]*\) .*/\1/p');;
    *) d="";;
esac
[ -n "$d" ] && [ -d "$d" ] && STATE=$d
BIN=${NEON_BIN:-/usr/local/bin/neond}
[ -f "$STATE/update.json" ] || exit 0
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
if [ -f "$STATE/update.alive" ] ||
    { [ -n "$boot" ] && [ "$(cat "$STATE/update.boot" 2>/dev/null)" != "$boot" ]; }; then
    rm -f "$STATE/update.alive" "$STATE/update.attempts"
fi
[ -n "$boot" ] && echo "$boot" > "$STATE/update.boot"
n=$(cat "$STATE/update.attempts" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$STATE/update.attempts"
# The first start after the update (or after a deliberate stop or a reboot) is n = 1; any
# other start before neond confirmed the update follows a crash or an exit.
if [ "$n" -gt 1 ] && [ -f "$BIN.prev" ]; then
    mv -f "$BIN.prev" "$BIN"
    rm -f "$STATE/update.json" "$STATE/update.attempts" "$STATE/update.boot"
    touch "$STATE/update.rolledback"
    echo "neon update-guard: the new neond did not stay up; previous version restored" >&2
fi
exit 0
