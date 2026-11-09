# Neon Network: releases

**A community LoRa network built on repurposed Helium IoT hotspots.** Website:
[element10.network](https://element10.network); the atoms on your network: [neon.directory](https://neon.directory).

Each repurposed hotspot is an **atom**: an always-on Meshtastic node for the local mesh, linked to the
other atoms over the internet (the **Plasma**: messages, channels and calls for the operators), and
earning **photons** for the coverage it proves, which become NEON tokens each week.

This repository holds the signed releases of `neond`, the atom software, and the scripts that install
it. The Release workflow of the source repository publishes here; nothing here is edited by hand.

## Repositories

| Repository | Contents |
|---|---|
| element10-network/NEON (private) | `neond`, the atom and electrode software; the design docs |
| element10-network/NEON-token (private) | The NEON token's Solana program, its client and the claim page |
| [element10-network/NEON-releases](https://github.com/element10-network/NEON-releases) (public) | Signed releases, the install scripts, the SD card image and the testers' guide |

## Install an atom

On a fresh Raspberry Pi OS Lite (64-bit) on a supported hotspot (tested: RAK Hotspot Miner V2):

```
curl -fsSL https://raw.githubusercontent.com/element10-network/NEON-releases/main/hardware/scripts/setup.sh | sudo sh
```

Then open neon.directory (no internet: `http://<hostname>.local`, or `http://<address>:8080`) and finish the setup page
(it asks for the 8-digit setup code the script prints at the end). Atoms
install new releases from here by themselves, between 03:00 and 05:00 UTC (panel: Settings → Updates).
A ready SD card image is the release
[`sd-image`](https://github.com/element10-network/NEON-releases/releases/tag/sd-image); in Raspberry Pi
Imager: **App options → Content repository → Use custom URL**
`https://github.com/element10-network/NEON-releases/releases/download/sd-image/os-list.json`, then
**Neon atom**, and your Wi-Fi in Imager's customisation.

Testers: start with [GUIDE.md](GUIDE.md).

## Checking a release

`release.txt` lists each binary with its size and SHA-256; `release.sig` is an Ed25519 signature of
`release.txt` by one of the keys in `hardware/release-keys.txt`. `setup.sh` and `neond` refuse a
release that does not check out. `scripts.txt` (signed the same way in `scripts.sig`) names the tree hash
of `hardware/` at the release's tag: `setup.sh` installs the scripts from that tag and checks them
against it before running any (releases before 0.4.206 have none; with `NEON_REF` given they are not
checked).

## License

GPL-3.0, the same license as Meshtastic.
