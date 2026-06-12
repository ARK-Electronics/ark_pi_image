# ark_pi_image

Builds a flashable **ARK-OS golden image** for the [ARK Just A Pi](https://docs.arkelectron.com/products/embedded-computers/ark-just-a-pi) carrier with a Raspberry Pi **Compute Module 5**. The output is a turnkey SD/eMMC image: flash it, plug the CM5 into the carrier, power on — carrier hardware configured and ARK-OS already installed. No Raspberry Pi Imager, no manual `config.txt` edits.

This automates the manual [flashing guide](https://docs.arkelectron.com/products/embedded-computers/ark-just-a-pi/flashing-guide) once, at build time.

## Build & flash

Linux host with `sudo`. x86_64 works (the arm64 chroot runs under qemu — slower); a native arm64 host or a Pi is faster. Needs ~10 GB free.

```bash
./build.sh --provision        # build the default justapi-cm5 image with ARK-OS
./flash.sh /dev/sdX           # write it to the SD card
```

- `build.sh` installs host tools and downloads the base image on first run (≈550 MB), then builds in an arm64 chroot. Expect 20–40 min on the first run, faster after: the base image, the debs, and the apt dependency cache (`downloads/apt-cache/`) are reused, so unchanged rebuilds skip the downloads. Output: `staging/justapi-cm5-trixie-ark-os.img`.
- `flash.sh` with no device lists removable candidates; re-run with the device. It refuses the host's system disk and re-prompts for the device path before writing.

Each step tees its full output to `staging/{setup,build,flash}.log.txt` for post-mortem.

Insert the card into the Just A Pi with the CM5 installed and power on. It comes up headless:

```bash
ssh pi@just-a-pi.local        # password: pi
```

No network? The USB-C flashing port doubles as **Ethernet-over-USB** (USB gadget mode): connect it to a computer and the Pi enumerates as a USB network adapter (CDC NCM — driverless on Linux, macOS, and Windows 11), hands the host a DHCP lease, and is reachable at `192.168.55.1` (or `just-a-pi.local`):

```bash
ssh pi@192.168.55.1           # over the USB-C cable, no network needed
```

Use a USB **A**-to-C cable: the carrier's USB-C has no CC resistors, so a Type-C host on a C-to-C cable never detects a device and never connects, while an A port supplies VBUS unconditionally — the same setup as rpiboot eMMC flashing. If it doesn't enumerate, try the C plug the other way up (CC-less ports can be orientation-sensitive). Power the board from its Molex input as usual; the USB-C is not a power input.

Gadget mode claims the USB-C's USB 2.0 pins, so they can't host USB2 devices at the same time (the JST-GH USB2 host port is unaffected). To trade Ethernet-over-USB for a USB2 host port on the USB-C, use the baked-in toggle — `dr_mode` is fixed at boot, so switching takes a reboot:

```bash
sudo ark-usb-mode host        # USB-C becomes a USB2 host port (after reboot)
sudo ark-usb-mode gadget      # back to Ethernet-over-USB (after reboot)
ark-usb-mode status           # configured vs live mode
```

> **CM5 with onboard eMMC** has no SD slot — flash over USB instead. Short the `BOOT` jumper (next to UART4), connect USB-C to the host, run [`rpiboot`](https://www.raspberrypi.com/documentation/computers/compute-module.html#flashing-the-compute-module-emmc) so the eMMC appears as `/dev/sdX`, `./flash.sh /dev/sdX`, then remove the jumper and boot.

> **Before shipping real units, change the baked `pi`/`pi` password** in `versions.env` (it's stored identically on every card). For a production line, prefer Pi OS's `userconf.txt` first-boot mechanism.

---

## Targets

A *target* (`targets/*.target`) is a carrier × compute-module pair. It sets the hostname and the `config.txt` overlays baked into the image. Select one with `./build.sh <target>` or `TARGET=` in `versions.env`; output is `staging/<target>-<codename>[-ark-os].img`.

| Target | Carrier + module | Status |
|---|---|---|
| `justapi-cm5` *(default)* | Just A Pi + CM5 | supported |
| `pi6x-cm4` | Pi6X Flow + CM4 | stub — config transcribed from docs, untested; gated off |

`pi6x-cm4` refuses to build until validated: remove its `TARGET_STUB=1` line. Add a target by copying an existing file and setting `TARGET_HOSTNAME`, `CONFIG_TXT_DISABLE`, and `CONFIG_TXT_APPEND`. Targets whose dwc2 USB port is free to run in device mode can also set `TARGET_USB_GADGET=1` to ship the Ethernet-over-USB gadget (`files/usb-gadget/`): a configfs NCM gadget service, a NetworkManager shared-mode profile (`192.168.55.1/24`, DHCP for the host), and the `ark-usb-mode` gadget/host toggle — the dwc2 `dr_mode=peripheral` switch stays in the target's `config.txt` keys.

## What's in the image

Pinned in `versions.env`:

- **Base:** Raspberry Pi OS Lite arm64, **Trixie (Debian 13)** — URL + sha256. One release at a time; for Bookworm, check out an older tag.
- **ARK-OS:** `ark-os-pi-trixie` (`ARK_OS_VERSION`), built against Debian 13 / python3.13 to match the base. Installed only with `--provision`. The deb's `preinst` enforces the codename match, and its services run as user `pi`.
- **MAVSDK:** bundled inside the ark-os deb under `/usr/lib/ark-os/mavsdk` (since [ARK-Electronics/ARK-OS#75](https://github.com/ARK-Electronics/ARK-OS/pull/75)) — nothing to install or pin here, and the image carries no system-wide MAVSDK, so installing your own never touches ARK-OS. `provision.sh` asserts the installed deb actually ships the bundled library.

To move to a newer Pi OS release, bump the base URL/sha256 + `PIOS_RELEASE` together and rebuild the ARK-OS deb for that release.

Every image carries `/etc/ark-os-image.json` recording what built it: the `ark_pi_image` commit (`git describe`, with a `-dirty` suffix if built from uncommitted changes), base-image sha256, target, build time, and the installed ARK-OS version plus the MAVSDK it bundles.

## Without `--provision`

`./build.sh` alone produces a stock Pi OS image with only the carrier config baked (hostname, `config.txt`, the `pi` user, SSH) — no ARK-OS. Output drops the `-ark-os` suffix.

## Dev mode (unreleased ARK-OS)

ARK-OS CI artifacts are versioned `0.0.0-<sha8>` and never published as releases. To build against one, drop the `ark-os-pi-trixie_*_arm64.deb` into `downloads/` and set `ARK_OS_VERSION=""`; the build installs the newest matching deb it finds there.

## First-boot finalization

The image is only chrooted, never booted, so per-device steps run on the device's first boot: Pi OS regenerates SSH host keys and `machine-id` and expands root to fill the card, and ARK-OS's `ark-os-firstboot` oneshot (enabled offline during the chroot install) sets up the default hotspot, flight-review DB, and Wi-Fi unblock once.

## License

MIT — see [LICENSE](LICENSE). Flashed images bundle ARK-OS and MAVSDK, which carry their own licenses.
