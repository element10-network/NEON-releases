# Neon Network: releases

Signed releases of `neond`, the software of a Neon Network atom, and the scripts that install it.
The Release workflow of the (private) source repository publishes here; nothing here is edited by hand.

## Install an atom

On a fresh Raspberry Pi OS Lite (64-bit) on a supported hotspot (RAK Hotspot Miner V2):

```
curl -fsSL https://raw.githubusercontent.com/element10-network/NEON-releases/main/hardware/scripts/setup.sh | sudo sh
```

Then open `http://<hostname>.local` (or `http://<address>:8080`) and finish the setup page.
Atoms install new releases from here by themselves, at night (panel: Settings → Updates).

Testers: start with [GUIDE.md](GUIDE.md).

A ready SD card image is the release [`sd-image`](https://github.com/element10-network/NEON-releases/releases/tag/sd-image).

## Checking a release

`release.txt` lists each binary with its size and SHA-256; `release.sig` is an Ed25519 signature
of `release.txt` by one of the keys in `hardware/release-keys.txt`. `setup.sh` and `neond` refuse
a release that does not check out.
