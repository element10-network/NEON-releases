# Neon Network: releases

**A community LoRa network built on repurposed Helium IoT hotspots.** Website:
[element10.network](https://element10.network).

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

Then open `http://<hostname>.local` (or `http://<address>:8080`) and finish the setup page. Atoms
install new releases from here by themselves, between 03:00 and 05:00 UTC (panel: Settings → Updates).
A ready SD card image is the release
[`sd-image`](https://github.com/element10-network/NEON-releases/releases/tag/sd-image).

Testers: start with [GUIDE.md](GUIDE.md).

## Checking a release

`release.txt` lists each binary with its size and SHA-256; `release.sig` is an Ed25519 signature of
`release.txt` by one of the keys in `hardware/release-keys.txt`. `setup.sh` and `neond` refuse a
release that does not check out.

## License

GPL-3.0, the same license as Meshtastic.
