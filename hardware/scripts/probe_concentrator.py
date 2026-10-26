#!/usr/bin/env python3
"""Find a LoRa concentrator's chip type, SPI device, power pin and reset GPIO on a Raspberry Pi.

Run on the hotspot with the packet forwarder stopped:
    sudo apt-get install -y python3-spidev
    sudo python3 hardware/scripts/probe_concentrator.py

1. Reads the chip version on every /dev/spidev*, using both the SX1301 SPI format
   (version register = 103) and the SX1302/SX1303 format (version register at 0x5606).
2. If nothing answers, tries each free GPIO two ways: pulsed (a reset line left asserted)
   and held high (a power-enable line).
3. Once a chip answers, writes its page register (a value that a reset clears), pulses
   each GPIO, and reads it back. The GPIO that clears it is the reset line.

It only toggles free GPIOs, and leaves out the SPI0, I2C1 and UART pins.
"""

import glob
import os
import sys
import time

try:
    import spidev
except ImportError:
    sys.exit("python3-spidev is missing: sudo apt-get install -y python3-spidev")

SYSFS = os.environ.get("NEON_GPIO_SYSFS", "/sys/class/gpio")  # overridable for testing
SPI_GLOB = os.environ.get("NEON_SPI_GLOB", "/dev/spidev*")  # overridable for testing
SPI_HZ = 1_000_000  # slower than the HALs use, to rule out signal problems
# Free BCM GPIOs on the 40-pin header. Leaves out 2/3 (I2C1 with the ECC608),
# 7-11 (SPI0) and 14/15 (UART).
CANDIDATES = [4, 5, 6, 12, 13, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27]
SPEEDS = [500_000, 1_000_000, 2_000_000, 4_000_000, 8_000_000]


class Sx1301:
    name = "SX1301"
    hal = "sx1301"

    def __init__(self, spi):
        self.spi = spi

    def read(self, addr):
        return self.spi.xfer2([addr & 0x7F, 0x00])[1]

    def write(self, addr, value):
        self.spi.xfer2([0x80 | (addr & 0x7F), value & 0xFF])

    def version(self):
        return self.read(1)

    def answers(self):
        return self.version() == 103

    def set_page(self, page):
        self.write(0, page)

    def page(self):
        return self.read(0) & 0x03


class Sx1302:
    name = "SX1302/SX1303"
    hal = "sx1302"
    MUX = 0x00  # LGW_SPI_MUX_TARGET_SX1302
    PAGE = 0x5600  # COMMON_PAGE
    VERSION = 0x5606  # COMMON_VERSION, typically 0x10

    def __init__(self, spi):
        self.spi = spi

    def read(self, addr):
        return self.spi.xfer2([self.MUX, (addr >> 8) & 0x7F, addr & 0xFF, 0x00, 0x00])[4]

    def write(self, addr, value):
        self.spi.xfer2([self.MUX, 0x80 | ((addr >> 8) & 0x7F), addr & 0xFF, value & 0xFF])

    def version(self):
        return self.read(self.VERSION)

    def answers(self):
        # The page register must hold a written value, which rules out a floating bus.
        if self.version() in (0x00, 0xFF):
            return False
        self.set_page(2)
        ok = self.page() == 2
        self.set_page(0)
        return ok

    def set_page(self, page):
        self.write(self.PAGE, page)

    def page(self):
        return self.read(self.PAGE) & 0x03


def open_spi(path):
    bus, dev = os.path.basename(path).removeprefix("spidev").split(".")
    spi = spidev.SpiDev()
    spi.open(int(bus), int(dev))
    spi.max_speed_hz = SPI_HZ
    spi.mode = 0
    return spi


def find_chip(devices, quiet=False):
    """Return (path, chip) for the first device where a concentrator answers, else None."""
    for path in devices:
        spi = open_spi(path)
        for kind in (Sx1301, Sx1302):
            chip = kind(spi)
            if not quiet:
                print(f"  {path}: {chip.name} format reads version {chip.version()}")
            if chip.answers():
                return path, chip
        spi.close()
    return None


def gpio_base():
    """sysfs number of BCM GPIO 0 (0 on old kernels, 512 on Raspberry Pi OS kernels 6.6+)."""
    for chip in sorted(glob.glob(f"{SYSFS}/gpiochip*")):
        with open(f"{chip}/label") as f:
            label = f.read().strip()
        if label.startswith("pinctrl-bcm"):
            with open(f"{chip}/base") as f:
                return int(f.read())
    sys.exit("no pinctrl-bcm GPIO controller found (is this a Raspberry Pi?)")


def sysfs_write(path, value):
    with open(path, "w") as f:
        f.write(str(value))


class Pin:
    """A GPIO driven through sysfs. Released (input, unexported) on close."""

    def __init__(self, base, line):
        self.line = line
        self.n = base + line
        self.path = f"{SYSFS}/gpio{self.n}"
        self.exported_here = not os.path.isdir(self.path)
        if self.exported_here:
            sysfs_write(f"{SYSFS}/export", self.n)
            time.sleep(0.1)
        sysfs_write(f"{self.path}/direction", "out")

    def set(self, value):
        sysfs_write(f"{self.path}/value", value)
        time.sleep(0.1)

    def pulse(self):
        self.set(1)
        self.set(0)

    def close(self):
        try:
            sysfs_write(f"{self.path}/direction", "in")
            if self.exported_here:
                sysfs_write(f"{SYSFS}/unexport", self.n)
        except OSError:
            pass


def open_pin(base, line):
    try:
        return Pin(base, line)
    except OSError as e:
        print(f"  GPIO {line}: skipped ({e.strerror})")
        return None


def main():
    devices = sorted(glob.glob(SPI_GLOB))
    if not devices:
        sys.exit("no /dev/spidev* devices: enable SPI with `sudo raspi-config nonint do_spi 0` and reboot")
    base = gpio_base()
    power = None  # a pin that must stay high, if one is found

    print("Step 1: chip version on each SPI device")
    found = find_chip(devices)

    if found is None:
        print("\nStep 2: nothing answered. Trying each GPIO as a reset line (pulse) and as a power enable (hold high)...")
        for line in CANDIDATES:
            pin = open_pin(base, line)
            if pin is None:
                continue
            pin.pulse()
            found = find_chip(devices, quiet=True)
            if found:
                print(f"  the chip answered after pulsing GPIO {line}")
                pin.close()
                break
            pin.set(1)
            found = find_chip(devices, quiet=True)
            if found:
                print(f"  the chip answered while GPIO {line} is held HIGH: that is a power-enable pin")
                power = pin  # keep it high for step 3
                break
            pin.set(0)
            pin.close()

    if found is None:
        print("\nResult: no concentrator answered on any SPI device, in either SX1301 or SX1302 format.")
        print("Check the concentrator card is seated in its socket and the HAT is firmly on the header.")
        print("Please also read the model printed on the concentrator card (e.g. RAK2245, RAK2287,")
        print("RAK5146) and paste it with this output into the Neon session.")
        return 1

    path, chip = found
    print(f"\nFound {chip.name} on {path} (version register {chip.version()}).")

    # The HALs clock SPI at 2 MHz (SX1302) or 8 MHz (SX1301); some boards cannot.
    print("\nSPI speed check (the chip must answer at the HAL's speed):")
    hal_hz = 2_000_000 if chip.hal == "sx1302" else 8_000_000
    fastest_ok = None
    for hz in SPEEDS:
        chip.spi.max_speed_hz = hz
        ok = chip.answers()
        print(f"  {hz / 1e6:g} MHz: {'ok' if ok else 'NO ANSWER'}")
        if ok and (fastest_ok is None or hz > fastest_ok):
            fastest_ok = hz
    chip.spi.max_speed_hz = SPI_HZ
    slow_spi = fastest_ok is not None and fastest_ok < hal_hz
    print(f"\nStep 3: finding the reset GPIO (sysfs base {base})")
    hits = []
    for line in CANDIDATES:
        if power is not None and line == power.line:
            continue
        chip.set_page(1)
        if chip.page() != 1:
            print("  the page register does not hold a written value; the SPI link is unreliable")
            return 1
        pin = open_pin(base, line)
        if pin is None:
            continue
        pin.pulse()
        pin.close()
        if chip.page() == 0 and chip.answers():
            print(f"  GPIO {line}: resets the chip")
            hits.append(line)
    chip.set_page(0)
    chip.spi.close()
    if power is not None:
        power.close()

    print(f"\nResult: {chip.name} on {path}. Put these in hardware/devices/rak-v2.env:")
    print(f"  NEON_SPI={path}")
    if power is not None:
        print(f"  NEON_POWER_GPIO_LINE={power.line}")
    if slow_spi:
        print(f"  NEON_SPI_HZ={fastest_ok}   # the HAL's default {hal_hz / 1e6:g} MHz is too fast for this board")
    if hits:
        print(f"  NEON_RESET_GPIO_LINE={hits[0]}")
        if len(hits) > 1:
            print(f"  (several GPIOs reset the chip: {hits}; using the first)")
    else:
        print("  (no GPIO reset the chip; paste this output into the Neon session)")
    print(f"Then rebuild: sudo hardware/scripts/install.sh rak-v2 EU868 {chip.hal}")
    return 0 if hits else 1


if __name__ == "__main__":
    sys.exit(main())
