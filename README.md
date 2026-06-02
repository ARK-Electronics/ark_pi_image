# ark_pi_image

Build a flashable **ARK-OS Raspberry Pi golden image** and write it to an SD card (or CM4/CM5 eMMC) without ever opening Raspberry Pi Imager. Three steps:

```
./setup.sh                  # install host tools + download the stock Raspberry Pi OS image
./build.sh [target] [--provision]   # bake board config; --provision adds ark-os-pi-bookworm + MAVSDK
./flash.sh /dev/sdX         # write the finished image to an SD card / eMMC
```

The result is a deterministic, turnkey image: every card flashed from it is identical, boots offline, and comes up with *the carrier's hardware already configured* — and, when built with `--provision`, with ARK-OS installed too. It's the production-line analogue of `ark_jetson_kernel --provision`, but far simpler because there is no kernel to build and no NVIDIA recovery-mode flashing.

> **Status.** Not yet validated on hardware. The build runs end to end; the chroot/partition plumbing in `build.sh` is the part most likely to need tuning on a given host, and only the `pi6x-cm4` target's `config.txt` is taken verbatim from hardware docs (see [Targets](#targets)).

## Targets

A *target* is a **carrier board × compute module** pair. It decides the hostname and the `config.txt` overlays baked into the image, so one builder produces turnkey images for several boards. Pick one with `./build.sh <target>` (or set `TARGET=` in `versions.env`); the output is named `<target>-<codename>.img` (or `<target>-<codename>-ark-os.img` when built with `--provision`).

| Target | Board | Hostname | Notes |
|---|---|---|---|
| `pi6x-cm4` *(default)* | ARK Pi6X Flow (onboard ARKV6X) + CM4 | `pi6x` | populated — `config.txt` verbatim from the flashing guide |
| `pi6x-cm5` | ARK Pi6X Flow + CM5 | `pi6x` | **stub** — CM5 specifics TBD (won't build yet) |
| `justapi-cm4` | "Just A Pi" plain carrier + CM4 | `pi` | **stub** — carrier specifics TBD (won't build yet) |
| `justapi-cm5` | "Just A Pi" plain carrier + CM5 | `pi` | **stub** — TBD (won't build yet) |

Each target is a small file in `targets/`. Only `pi6x-cm4` is populated today; `pi6x-cm5`, `justapi-cm4`, and `justapi-cm5` are stubs (`TARGET_STUB=1`) that refuse to build until their specifics are filled in. To populate one, copy `targets/pi6x-cm4.target`, set `TARGET_HOSTNAME`, list the lines to comment out (`CONFIG_TXT_DISABLE`) and append (`CONFIG_TXT_APPEND`) in `config.txt`, and delete the `TARGET_STUB` line.

With `--provision`, all four targets install the **same** `ark-os-pi-bookworm` deb — there is one ARK-OS build for the Pi, and the golden images differ only in baked configuration (hostname + `config.txt`). Choosing which services run or which configs get written per carrier is left to ARK-OS runtime logic, to be added later.

The **Pi OS release** is the other axis, pinned in `versions.env` — Bookworm today; `PIOS_RELEASE` plus the image URL/sha move together to add Trixie once ARK-OS ships a Trixie deb. (`config.txt` is at `/boot/firmware/config.txt` for both.)

## What it bakes (vs. the manual flashing guide)

The [Pi6X Flow flashing guide](https://docs.arkelectron.com/products/flight-controller/ark-pi6x-flow/flashing-guide) walks a user through doing this by hand; the golden image does it once, at build time:

| Manual step in the guide | Handled by |
|---|---|
| Flash Raspberry Pi OS Lite (64-bit, Bookworm) | `versions.env` base-image pin |
| Imager: create the `pi` user + password | `configure_target.sh` (baked account) |
| Edit `config.txt` (UART / camera / fan / GPIO overlays) | `configure_target.sh`, from the selected `targets/*.target` |
| Set the hostname (`pi6x` → `http://pi6x.local/`) | `configure_target.sh`, from the target |
| Enable SSH | `configure_target.sh` (`ENABLE_SSH=1`) |
| Install ARK-OS + enable services | `provision.sh`, with `--provision` (ark-os-pi-bookworm deb + `ark-os-firstboot`) |
| Wi-Fi credentials | left to the user / the deb's first-boot hotspot (site-specific) |

## How it works

| Script | What it does |
|---|---|
| `setup.sh` | Installs host deps (`qemu-user-static`, `binfmt-support`, `parted`, `xz-utils`, `curl`), registers the `qemu-aarch64` binfmt handler, and downloads the stock Raspberry Pi OS Lite arm64 image into `downloads/`. |
| `build.sh` | Resolves the target, copies the stock image to `staging/`, grows its root partition, loop-mounts it, bind-mounts `/proc /sys /dev`, runs `configure_target.sh` (and, with `--provision`, `provision.sh`) in an `arm64` chroot (emulated via qemu on an x86 host), and reports how long the build took. Produces `staging/<target>-<codename>.img` (or `…-ark-os.img` with `--provision`). |
| `configure_target.sh` | Always runs. Bakes the `pi` user, sets the hostname, applies the target's `config.txt` edits, and enables SSH. |
| `provision.sh` | The ARK-OS payload, only with `--provision`: blocks daemon starts with a `policy-rc.d` shim, then `apt-get install`s MAVSDK and the `ark-os-pi-bookworm` deb and verifies them. |
| `flash.sh` | Writes `staging/*.img` to a target block device, with size/model confirmation and guards against writing to a system disk. |

Pins (base image, ARK-OS/MAVSDK versions, baked user, target) live in `versions.env`; per-board hardware config lives in `targets/`.

## Requirements

- A Linux host with `sudo`. x86_64 works (arm64 binaries run under qemu); a native arm64 host (or a Pi) works too and is faster.
- For `--provision` builds, the `ark-os-pi-bookworm_<ver>_arm64.deb`. Until PR #68 is released, drop a CI-artifact deb into `downloads/` and set `ARK_OS_VERSION` in `versions.env` to its `0.0.0-<sha8>`.

## Flashing to CM4/CM5 eMMC

`flash.sh` just `dd`s to a block device, so eMMC works once the module is exposed as one: short the carrier's `BOOT`/`nRPIBOOT` jumper, plug the USB port into the host, run `rpiboot`, and the eMMC appears as `/dev/sdX`. Flash it like a card, then remove the jumper to boot normally.

## Notes / open items

- **Change the baked password** (`versions.env`) before shipping real hardware; the appliance default is `pi` / `raspberry`.
- **Only `pi6x-cm4` is populated.** The other three targets are stubs (`TARGET_STUB=1`) and refuse to build until their `config.txt` overlays are filled in from hardware docs — CM5's RP1 changes UART numbering and fan handling, and the Just-A-Pi carrier isn't characterised yet.
- **First-boot finalization.** The deb's postinst defers a few runtime-only steps (default hotspot, flight-review DB, Wi-Fi unblock) into the `ark-os-firstboot` oneshot, which the chroot install enables (a static `WantedBy=multi-user.target` symlink that works offline). A baked card finishes configuring itself on first boot, guarded by a sentinel so it runs once.
- **Per-device uniqueness is inherited.** Because we only chroot (never boot) the stock image, Pi OS's own first-boot machinery still runs on the device: SSH host keys regenerate, `/etc/machine-id` is generated, and root expands to fill the card.
