#!/bin/sh
# Pulse the LoRa concentrator's reset line.
#
# sx1302_hal's lora_pkt_fwd and chip_id run "./reset_lgw.sh start|stop" from
# their working directory. For SX1301 forwarders, the systemd unit runs it
# before starting.
#
# Settings come from device.env next to this script:
#   NEON_RESET_GPIO_CHIP  GPIO controller label or register address (e.g. fe200000)
#   NEON_RESET_GPIO_LINE  line offset within that controller
#   NEON_RESET_GPIO       alternatively, a raw sysfs GPIO number
#   NEON_POWER_GPIO_LINE  optional power-enable line on the same controller, driven high on start
#
# The controller is looked up at run time because newer kernels (6.6+) no
# longer give GPIO controllers fixed sysfs numbers. A kernel without the sysfs
# GPIO interface at all (Armbian, a Nebra) is driven with libgpiod's gpioset
# (v1 or v2) instead (verify on the Nebra).

set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
if [ -f "$DIR/device.env" ]; then
    . "$DIR/device.env"
fi

# Overridable for testing only.
SYSFS=${NEON_GPIO_SYSFS:-/sys/class/gpio}

# resolve_gpio <line>: sysfs number of a line on NEON_RESET_GPIO_CHIP.
resolve_gpio() {
    : "${NEON_RESET_GPIO_CHIP:?set NEON_RESET_GPIO_CHIP or NEON_RESET_GPIO in device.env}"
    for chip in "$SYSFS"/gpiochip*; do
        label=$(cat "$chip/label")
        dev=$(readlink -f "$chip/device" 2>/dev/null || true)
        case "$label $dev" in
            *"$NEON_RESET_GPIO_CHIP"*)
                echo $(( $(cat "$chip/base") + $1 ))
                return
                ;;
        esac
    done
    echo "ERROR: no GPIO controller matches '$NEON_RESET_GPIO_CHIP'. Available:" >&2
    for chip in "$SYSFS"/gpiochip*; do
        echo "  $chip label=$(cat "$chip/label") base=$(cat "$chip/base") device=$(readlink -f "$chip/device" 2>/dev/null || true)" >&2
    done
    exit 1
}

# No sysfs GPIO: the controller's character device (/dev/gpiochipN) and gpioset.
if [ ! -e "$SYSFS/export" ] && [ -z "${NEON_GPIO_SYSFS:-}" ] && command -v gpioset >/dev/null; then
    : "${NEON_RESET_GPIO_CHIP:?set NEON_RESET_GPIO_CHIP in device.env (libgpiod needs the controller)}"
    : "${NEON_RESET_GPIO_LINE:?set NEON_RESET_GPIO_LINE in device.env}"
    CHIPDEV=""
    for chip in /sys/bus/gpio/devices/gpiochip*; do
        [ -e "$chip" ] || continue
        label=$(cat "$chip/label" 2>/dev/null || true)
        dev=$(readlink -f "$chip" 2>/dev/null || true)
        case "$label $dev" in
            *"$NEON_RESET_GPIO_CHIP"*) CHIPDEV=$(basename "$chip"); break ;;
        esac
    done
    [ -n "$CHIPDEV" ] || { echo "ERROR: no GPIO controller matches '$NEON_RESET_GPIO_CHIP' (libgpiod)" >&2; ls /sys/bus/gpio/devices/ >&2 || true; exit 1; }
    # set <line> <0|1>: v2 holds the line until stopped (-t 0: set and exit); v1 sets and exits.
    set_line() {
        if gpioset --version 2>/dev/null | grep -q 'v2'; then
            gpioset -c "$CHIPDEV" -t 0 "$1=$2"
        else
            gpioset "$CHIPDEV" "$1=$2"
        fi
        sleep 0.1
    }
    case "${1:-}" in
        start)
            if [ -n "${NEON_POWER_GPIO_LINE:-}" ]; then
                echo "Concentrator power on through $CHIPDEV line $NEON_POWER_GPIO_LINE"
                set_line "$NEON_POWER_GPIO_LINE" 1
            fi
            echo "Concentrator reset through $CHIPDEV line $NEON_RESET_GPIO_LINE"
            set_line "$NEON_RESET_GPIO_LINE" 1
            set_line "$NEON_RESET_GPIO_LINE" 0
            ;;
        stop)
            set_line "$NEON_RESET_GPIO_LINE" 1
            set_line "$NEON_RESET_GPIO_LINE" 0
            ;;
        *)
            echo "Usage: $0 {start|stop}" >&2
            exit 1
            ;;
    esac
    exit 0
fi

if [ -n "${NEON_RESET_GPIO:-}" ]; then
    GPIO=$NEON_RESET_GPIO
else
    : "${NEON_RESET_GPIO_LINE:?set NEON_RESET_GPIO_LINE in device.env}"
    GPIO=$(resolve_gpio "$NEON_RESET_GPIO_LINE")
fi
POWER=""
if [ -n "${NEON_POWER_GPIO_LINE:-}" ]; then
    POWER=$(resolve_gpio "$NEON_POWER_GPIO_LINE")
fi

# drive <gpio> <0|1>
drive() {
    if [ ! -d "$SYSFS/gpio$1" ]; then
        echo "$1" > "$SYSFS/export"
        sleep 0.1
    fi
    echo out > "$SYSFS/gpio$1/direction"
    echo "$2" > "$SYSFS/gpio$1/value"
    sleep 0.1
}

pulse() {
    drive "$GPIO" 1
    drive "$GPIO" 0
}

case "${1:-}" in
    start)
        if [ -n "$POWER" ]; then
            echo "Concentrator power on through GPIO $POWER"
            drive "$POWER" 1
        fi
        echo "Concentrator reset through GPIO $GPIO"
        pulse
        ;;
    stop)
        pulse
        echo "$GPIO" > "$SYSFS/unexport" 2>/dev/null || true
        ;;
    *)
        echo "Usage: $0 {start|stop}" >&2
        exit 1
        ;;
esac
