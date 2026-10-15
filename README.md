# ark_pi_image

Golden images for ARK's Raspberry Pi Compute Module carriers: Raspberry Pi OS with the carrier's `config.txt` baked in and [ARK-OS](https://github.com/ARK-Electronics/ARK-OS) installed.

| Target | Carrier + module | Hostname | Download |
|---|---|---|---|
| `pi6x-cm4` | [ARK Pi6X Flow](https://docs.arkelectron.com/products/flight-controller/ark-pi6x-flow) + CM4 | `pi6x.local` | [pi/pi6x/latest](https://downloads.arkelectron.com/pi/pi6x/latest/) |
| `pi6x-cm5` | ARK Pi6X Flow + CM5 | `pi6x.local` | [pi/pi6x/latest](https://downloads.arkelectron.com/pi/pi6x/latest/) |
| `justapi-cm5` | [ARK Just A Pi](https://docs.arkelectron.com/products/embedded-computers/ark-just-a-pi) + CM5 | `just-a-pi.local` | [pi/just-a-pi/latest](https://downloads.arkelectron.com/pi/just-a-pi/latest/) |
| `justapi-cm4` | ARK Just A Pi + CM4 | `just-a-pi.local` | [pi/just-a-pi/latest](https://downloads.arkelectron.com/pi/just-a-pi/latest/) |

Each carrier's docs list what a given compute module can't use on it.

## Flash

Write `<target>-trixie-ark-os.img.xz` with [Raspberry Pi Imager](https://www.raspberrypi.com/software/) (**Use custom**, no OS customisation, which would override the login and hostname), or with `./flash.sh --target <target>` from a clone (see [Build](#build)).

A module with eMMC needs [`rpiboot`](https://www.raspberrypi.com/documentation/computers/compute-module.html#flashing-the-compute-module-emmc) to expose it as a USB drive first:

- **Pi6X:** short the `BOOT` header next to the micro USB and connect the micro USB. Remove the jumper afterwards.
- **Just A Pi:** hold `BOOT` while powering on and connect the USB JST-GH port.

Log in with `ssh pi@<hostname>`, password `raspberry`.

## What's in the image

- **Base:** Raspberry Pi OS Lite arm64, Trixie, pinned by URL and sha256 in `versions.env`.
- **ARK-OS:** `ark-os-pi-trixie` at `ARK_OS_VERSION` (`versions.env`), with MAVSDK bundled inside the deb. Its services run as `pi`. `dds-agent` ships disabled; on `pi6x-cm5`, set its serial device to `/dev/ttyAMA3` on the Services page.
- **Cameras:** every target loads `imx708` (Camera Module 3), the camera ARK tests in production. Compute modules don't auto-detect cameras: for another sensor, change the `dtoverlay=imx708` lines in `/boot/firmware/config.txt` (`imx219` = Camera Module 2, `imx477` = HQ).
- **Just A Pi CAM2:** the carrier ties that connector's camera power enable high, so a Camera Module 3 there misses its power-on reset. `ark-imx708-reset.service` resets it over I2C at boot.
- **Build record:** `/etc/ark-os-image.json` holds the `ark_pi_image` commit, base-image sha256, target, build time and ARK-OS version.

The image is built in a chroot and never booted, so the first boot finishes it: Raspberry Pi OS expands the root filesystem and regenerates the SSH host keys, and ARK-OS's `ark-os-firstboot` creates the Wi-Fi hotspot and the flight-review database.

## Build

Needs a Linux host with `sudo` and ~10 GB free. x86_64 builds the arm64 chroot under qemu.

```bash
./build.sh --target pi6x-cm4 --provision   # staging/pi6x-cm4-trixie-ark-os.img
./flash.sh --target pi6x-cm4               # finds the SD card, asks y/N
```

- Without `--target`, both prompt with a list of targets.
- The first build downloads the base image (~550 MB) into `downloads/`, which also caches the debs between builds. A warm build takes about 5 minutes.
- `flash.sh` refuses partitions and any disk behind the host's system mounts or swap. Without a terminal, pass the device: `./flash.sh --target pi6x-cm4 /dev/sdX`.
- Logs go to `staging/{setup,build,flash}.log.txt`.
- Without `--provision`, the image has the carrier config but no ARK-OS, and its name drops `-ark-os`.
- To build against an unreleased ARK-OS (`0.0.0-<sha8>` CI artifacts), put the `ark-os-pi-trixie_*_arm64.deb` in `downloads/` and set `ARK_OS_VERSION=""`.

To move to a newer Raspberry Pi OS release, update the base image URL, sha256 and `PIOS_RELEASE` in `versions.env` together, and build ARK-OS for that release.

## Targets

A target is a carrier × compute module, `targets/<name>.target`, sourced by `scripts/configure_target.sh`:

| Key | |
|---|---|
| `TARGET_HOSTNAME` | Required |
| `TARGET_DESC` | Shown in the target picker |
| `CONFIG_TXT_DISABLE` | Stock `config.txt` lines to comment out |
| `CONFIG_TXT_APPEND` | Block appended after `[all]` |
| `TARGET_MODULES` | Kernel modules to load at boot |
| `TARGET_UNITS` | systemd units from `targets/units/` to install and enable |

`scripts/` holds what `build.sh` and `flash.sh` run: host setup, target configuration, ARK-OS install, and shared helpers.

## Releases

Each carrier has its own tag: `pi6x-v<major>.<minor>.<patch>` or `just-a-pi-v<major>.<minor>.<patch>`.

1. Pushing the tag runs **Release**, which builds every `targets/<carrier>-*.target` (`just-a-pi` builds `justapi-*`) and keeps the compressed images as run artifacts.
2. Bench-test those files: `gh run download <run-id>`.
3. Run **Publish to downloads.arkelectron.com** with the tag. It uploads to `downloads.arkelectron.com/pi/<carrier>/<version>/` and makes that version `latest/`.

Release can also run by hand on a branch to build test images; those runs are never published.

## License

MIT, see [LICENSE](LICENSE). The images bundle ARK-OS and MAVSDK, which carry their own licenses.
