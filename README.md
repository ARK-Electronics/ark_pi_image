# ark_pi_image

Builds Raspberry Pi OS images for ARK's Compute Module carriers, with the carrier's `config.txt` and [ARK-OS](https://github.com/ARK-Electronics/ARK-OS) baked in. Released images are on [downloads.arkelectron.com/pi](https://downloads.arkelectron.com/pi/).

| Carrier | Designed for | Also works, with limitations | Hostname |
|---|---|---|---|
| [ARK Pi6X Flow](https://docs.arkelectron.com/products/flight-controller/ark-pi6x-flow) | `pi6x-cm4` | `pi6x-cm5` | `pi6x.local` |
| [ARK Just A Pi](https://docs.arkelectron.com/products/embedded-computers/ark-just-a-pi) | `justapi-cm5` | `justapi-cm4` | `just-a-pi.local` |

## Build and flash

Needs a Linux host with `sudo` and ~10 GB free.

```bash
./build.sh --target pi6x-cm4 --provision   # staging/pi6x-cm4-trixie-ark-os.img
./flash.sh --target pi6x-cm4               # finds the SD card, asks y/N
```

- Without `--target`, both prompt with a list of targets.
- The first build downloads the base image (~550 MB); later builds take about 5 minutes.
- `flash.sh` refuses partitions and any disk behind the host's system mounts or swap. To pick the device yourself: `./flash.sh --target pi6x-cm4 /dev/sdX`.
- Without `--provision`, the image has the carrier config but no ARK-OS.
- Logs go to `staging/{setup,build,flash}.log.txt`.

Boot the carrier and log in with `ssh pi@<hostname>`, password `raspberry`.

## eMMC

A compute module with eMMC is flashed over USB. Put the carrier in boot mode, run [`rpiboot`](https://www.raspberrypi.com/documentation/computers/compute-module.html#flashing-the-compute-module-emmc) to expose the eMMC as a drive, then `./flash.sh --target <target> /dev/sdX`.

- **Pi6X:** short the `BOOT` header next to the micro USB and connect the micro USB. Remove the jumper afterwards.
- **Just A Pi:** hold `BOOT` while powering on and connect the USB JST-GH port.

## What's in the image

Raspberry Pi OS Lite (64-bit, Trixie) and ARK-OS, at the versions pinned in `versions.env`. `/etc/ark-os-image.json` records what built the image.

The default camera is the Raspberry Pi Camera Module 3 (IMX708). For another camera, change the `dtoverlay=imx708` lines in `/boot/firmware/config.txt` (`imx219` = Camera Module 2, `imx477` = HQ).

### Carrier notes

- **Just A Pi, CAM2:** the carrier ties that connector's camera power enable high, so a Camera Module 3 there misses its power-on reset. `ark-imx708-reset.service` resets it over I2C at boot.
- **Pi6X with a CM5:** `dds-agent` defaults to `/dev/ttyAMA4`; set it to `/dev/ttyAMA3` on ARK-OS's Services page.

## Targets

A target is a carrier × compute module, `targets/<name>.target`:

| Key | |
|---|---|
| `TARGET_HOSTNAME` | Required |
| `TARGET_DESC` | Shown in the target picker |
| `CONFIG_TXT_DISABLE` | Stock `config.txt` lines to comment out |
| `CONFIG_TXT_APPEND` | Block appended after `[all]` |
| `TARGET_MODULES` | Kernel modules to load at boot |
| `TARGET_UNITS` | systemd units from `targets/units/` to install and enable |

## Releases

Each carrier has its own tag: `pi6x-v<major>.<minor>.<patch>` or `just-a-pi-v<major>.<minor>.<patch>`.

1. Pushing the tag runs **Release**, which builds every `targets/<carrier>-*.target` (`just-a-pi` builds `justapi-*`) and keeps the compressed images as run artifacts.
2. Bench-test those files: `gh run download <run-id>`.
3. Run **Publish to downloads.arkelectron.com** with the tag. It uploads to `downloads.arkelectron.com/pi/<carrier>/<version>/` and makes that version `latest/`.

Release can also run by hand on a branch to build test images; those runs are never published.
