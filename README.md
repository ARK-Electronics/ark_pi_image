# ark_pi_image

Builds a flashable **ARK-OS golden image** for ARK carrier boards with Raspberry Pi Compute Modules. The output is a turnkey SD/eMMC image: flash it, plug the module into the carrier, power on — carrier hardware configured and ARK-OS already installed. No Raspberry Pi Imager, no manual `config.txt` edits.

Supported targets:

| Target | Carrier + module | Hostname |
|---|---|---|
| `justapi-cm5` | [ARK Just A Pi](https://docs.arkelectron.com/products/embedded-computers/ark-just-a-pi) + CM5 | `just-a-pi.local` |
| `pi6x-cm4` | [ARK Pi6X Flow](https://docs.arkelectron.com/products/flight-controller/ark-pi6x-flow) + CM4 | `pi6x.local` |

This automates each carrier's manual flashing guide once, at build time ([Just A Pi](https://docs.arkelectron.com/products/embedded-computers/ark-just-a-pi/flashing-guide), [Pi6X Flow](https://docs.arkelectron.com/products/flight-controller/ark-pi6x-flow/flashing-guide)).

## Build & flash

Linux host with `sudo`. x86_64 works (the arm64 chroot runs under qemu — slower); a native arm64 host or a Pi is faster. Needs ~10 GB free.

```bash
./build.sh --target pi6x-cm4 --provision   # or justapi-cm5
./flash.sh --target pi6x-cm4               # auto-detects the SD card; confirms with y/N
```

Omit `--target` and both scripts prompt with a numbered list of carriers. Non-interactive/CI: pass `--target`, or set `TARGET=` in the environment.

- `build.sh` installs host tools and downloads the base image on first run (≈550 MB), then builds in an arm64 chroot. Expect 20–40 min on the first run, faster after: the base image, the debs, and the apt dependency cache (`downloads/apt-cache/`) are reused, so unchanged rebuilds skip the downloads. Output: `staging/<target>-trixie-ark-os.img`.
- `flash.sh` finds the sole removable USB/SD device (or lets you pick when several are present), shows device + image, and asks `Proceed? [y/N]`. It refuses the host's system disk. You can still pass a device path explicitly: `./flash.sh --target pi6x-cm4 /dev/sdX`.

Each step tees its full output to `staging/{setup,build,flash}.log.txt` for post-mortem.

Insert the card into the carrier with the compute module installed and power on. It comes up headless:

```bash
ssh pi@just-a-pi.local     # justapi-cm5; password: pi
ssh pi@pi6x.local          # pi6x-cm4;    password: pi
```

> **CM5 with onboard eMMC** has no SD slot — flash over USB instead. Short the `BOOT` jumper (next to UART4), connect USB-C to the host, run [`rpiboot`](https://www.raspberrypi.com/documentation/computers/compute-module.html#flashing-the-compute-module-emmc) so the eMMC appears as `/dev/sdX`, `./flash.sh --target justapi-cm5 /dev/sdX`, then remove the jumper and boot.

> **Before shipping real units, change the baked `pi`/`pi` password** in `versions.env` (it's stored identically on every card). For a production line, prefer Pi OS's `userconf.txt` first-boot mechanism.

---

## Targets

A *target* (`targets/*.target`) is a carrier × compute-module pair. It sets the hostname and the `config.txt` overlays baked into the image. Select one with `--target <name>` on `build.sh` / `flash.sh` (or `TARGET=` in the environment); output is `staging/<target>-<codename>[-ark-os].img`.

Add a target by copying an existing file and setting `TARGET_HOSTNAME`, `CONFIG_TXT_DISABLE`, and `CONFIG_TXT_APPEND`. Leave `TARGET_STUB=1` until the config has been validated on hardware — stubs refuse to build.

## What's in the image

Pinned in `versions.env`:

- **Base:** Raspberry Pi OS Lite arm64, **Trixie (Debian 13)** — URL + sha256. One release at a time; for Bookworm, check out an older tag.
- **ARK-OS:** `ark-os-pi-trixie` (`ARK_OS_VERSION`), built against Debian 13 / python3.13 to match the base. Installed only with `--provision`. The deb's `preinst` enforces the codename match, and its services run as user `pi`.
- **MAVSDK:** bundled inside the ark-os deb under `/usr/lib/ark-os/mavsdk` (since [ARK-Electronics/ARK-OS#75](https://github.com/ARK-Electronics/ARK-OS/pull/75)) — nothing to install or pin here, and the image carries no system-wide MAVSDK, so installing your own never touches ARK-OS. `provision.sh` asserts the installed deb actually ships the bundled library.

To move to a newer Pi OS release, bump the base URL/sha256 + `PIOS_RELEASE` together and rebuild the ARK-OS deb for that release.

Every image carries `/etc/ark-os-image.json` recording what built it: the `ark_pi_image` commit (`git describe`, with a `-dirty` suffix if built from uncommitted changes), base-image sha, target, build time, and the installed ARK-OS version plus the MAVSDK it bundles.

## Without `--provision`

`./build.sh --target <name>` alone produces a stock Pi OS image with only the carrier config baked (hostname, `config.txt`, the `pi` user, SSH) — no ARK-OS. Output drops the `-ark-os` suffix.

## Dev mode (unreleased ARK-OS)

ARK-OS CI artifacts are versioned `0.0.0-<sha8>` and never published as releases. To build against one, drop the `ark-os-pi-trixie_*_arm64.deb` into `downloads/` and set `ARK_OS_VERSION=""`; the build installs the newest matching deb it finds there.

## First-boot finalization

The image is only chrooted, never booted, so per-device steps run on the device's first boot: Pi OS regenerates SSH host keys and `machine-id` and expands root to fill the card, and ARK-OS's `ark-os-firstboot` oneshot (enabled offline during the chroot install) sets up the default hotspot, flight-review DB, and Wi-Fi unblock once.

## License

MIT — see [LICENSE](LICENSE). Flashed images bundle ARK-OS and MAVSDK, which carry their own licenses.
