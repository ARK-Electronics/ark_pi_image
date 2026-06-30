# ark_pi_image

Builds a flashable **ARK-OS golden image** for the [ARK Just A Pi](https://docs.arkelectron.com/products/embedded-computers/ark-just-a-pi) carrier with a Raspberry Pi **Compute Module 5**. The output is a turnkey SD/eMMC image: flash it, plug the CM5 into the carrier, power on — carrier hardware configured and ARK-OS already installed. No Raspberry Pi Imager, no manual `config.txt` edits.

This automates the manual [flashing guide](https://docs.arkelectron.com/products/embedded-computers/ark-just-a-pi/flashing-guide) once, at build time.

## Build & flash

Linux host with `sudo`. x86_64 works (the arm64 chroot runs under qemu — slower); a native arm64 host or a Pi is faster. Needs ~10 GB free.

```bash
./build.sh --provision        # build the default justapi-cm5 image with ARK-OS
./flash.sh /dev/sdX           # write it to the SD card
```

Opt-in payloads stack onto that. For a robotics image add ROS 2 + OpenCV, and the Hailo
AI accelerator stack, with `--robotics` / `--hailo` (see [Robotics provisioning](#robotics-provisioning-opt-in)):

```bash
./build.sh --provision --robotics --hailo   # ARK-OS + ROS 2 + OpenCV + Hailo
```

- `build.sh` installs host tools and downloads the base image on first run (≈550 MB), then builds in an arm64 chroot. Expect 20–40 min on the first run, faster after: the base image, the debs, and the apt dependency cache (`downloads/apt-cache/`) are reused, so unchanged rebuilds skip the downloads. Output: `staging/justapi-cm5-trixie-ark-os.img`.
- `flash.sh` with no device lists removable candidates; re-run with the device. It refuses the host's system disk and re-prompts for the device path before writing.

Each step tees its full output to `staging/{setup,build,flash}.log.txt` for post-mortem.

Insert the card into the Just A Pi with the CM5 installed and power on. It comes up headless:

```bash
ssh pi@just-a-pi.local        # password: pi
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

`pi6x-cm4` refuses to build until validated: remove its `TARGET_STUB=1` line. Add a target by copying an existing file and setting `TARGET_HOSTNAME`, `CONFIG_TXT_DISABLE`, and `CONFIG_TXT_APPEND`.

## What's in the image

Pinned in `versions.env`:

- **Base:** Raspberry Pi OS Lite arm64, **Trixie (Debian 13)** — URL + sha256. One release at a time; for Bookworm, check out an older tag.
- **ARK-OS:** `ark-os-pi-trixie` (`ARK_OS_VERSION`), built against Debian 13 / python3.13 to match the base. Installed only with `--provision`. The deb's `preinst` enforces the codename match, and its services run as user `pi`.
- **MAVSDK:** bundled inside the ark-os deb under `/usr/lib/ark-os/mavsdk` (since [ARK-Electronics/ARK-OS#75](https://github.com/ARK-Electronics/ARK-OS/pull/75)) — nothing to install or pin here, and the image carries no system-wide MAVSDK, so installing your own never touches ARK-OS. `provision.sh` asserts the installed deb actually ships the bundled library.

To move to a newer Pi OS release, bump the base URL/sha256 + `PIOS_RELEASE` together and rebuild the ARK-OS deb for that release.

Every image carries `/etc/ark-os-image.json` recording what built it: the `ark_pi_image` commit (`git describe`, with a `-dirty` suffix if built from uncommitted changes), base-image sha256, target, build time, the installed ARK-OS version plus the MAVSDK it bundles, and (when built with `--robotics`/`--hailo`) the ROS 2 and Hailo versions installed.

## Without `--provision`

`./build.sh` alone produces a stock Pi OS image with only the carrier config baked (hostname, `config.txt`, the `pi` user, SSH) — no ARK-OS. Output drops the `-ark-os` suffix.

## Robotics provisioning (opt-in)

Two extra flags layer a robotics toolchain onto the image. Both are **off by default**,
independent, and combinable with each other and with `--provision`:

```bash
./build.sh --robotics                 # ROS 2 + OpenCV on a stock + target-config image
./build.sh --provision --robotics     # …on top of ARK-OS
./build.sh --provision --hailo        # ARK-OS + the Hailo AI accelerator stack
./build.sh --provision --robotics --hailo   # the lot
```

The output image name records what went in: `-robotics` and/or `-hailo` are appended after
the `-ark-os` suffix (e.g. `justapi-cm5-trixie-ark-os-robotics-hailo.img`). `flash.sh` flashes
the newest matching image by default.

| Flag | Installs | From |
|---|---|---|
| `--robotics` | **ROS 2** (`ROS2_PACKAGE`, default `ros-jazzy-ros-base`) + colcon/rosdep dev tools, and **OpenCV** (`python3-opencv`, `libopencv-dev`) | ROS 2: the community [rospian](https://github.com/rospian/rospian-repo) apt repo; OpenCV: Debian |
| `--hailo` | The **Hailo** `hailo-all` stack (hailort runtime, firmware, rpicam/TAPPAS integration) and sets the carrier to **PCIe Gen 3** | Raspberry Pi apt repo (already in the base image) |

All of this is pinned/overridable in `versions.env` (ROS distro, package variant, apt repo
+ key, OpenCV package list, Hailo package). The base is Pi OS **Lite** (headless), so the ROS 2
default is `ros-base` — switch to `ros-jazzy-desktop`/`-desktop-full`/`-perception` if you want
rviz/gazebo and will attach a display. The rospian apt source is left in the image, so
`sudo apt install ros-jazzy-<pkg>` keeps working on the device. ROS 2 is auto-sourced for login
shells via `/etc/profile.d/ros2.sh`, so `ros2 …` works out of the box; run `rosdep update` once
on the device (needs network).

> **Caveats.** ROS 2 has **no official Debian/Trixie packages** — Debian is a Tier-3 platform and
> upstream recommends Docker; `--robotics` therefore relies on a community build farm. The Hailo
> M.2 module sits in the Just A Pi's PCIe/M.2 slot; `--hailo` enables PCIe Gen 3 for full bandwidth
> (the `hailo_pci` driver ships in the Pi kernel, so no DKMS build runs in the chroot). These paths
> haven't yet been validated on hardware — treat a robotics image as **experimental**. The manifest
> at `/etc/ark-os-image.json` records the ROS 2 and Hailo versions actually installed.

## Dev mode (unreleased ARK-OS)

ARK-OS CI artifacts are versioned `0.0.0-<sha8>` and never published as releases. To build against one, drop the `ark-os-pi-trixie_*_arm64.deb` into `downloads/` and set `ARK_OS_VERSION=""`; the build installs the newest matching deb it finds there.

## First-boot finalization

The image is only chrooted, never booted, so per-device steps run on the device's first boot: Pi OS regenerates SSH host keys and `machine-id` and expands root to fill the card, and ARK-OS's `ark-os-firstboot` oneshot (enabled offline during the chroot install) sets up the default hotspot, flight-review DB, and Wi-Fi unblock once.

## License

MIT — see [LICENSE](LICENSE). Flashed images bundle ARK-OS and MAVSDK, which carry their own licenses.
