# ark_pi_image

Build a flashable **ARK-OS Raspberry Pi golden image** and write it to an SD card (or CM4/CM5 eMMC) without ever opening Raspberry Pi Imager. Three steps:

```
./setup.sh                  # install host tools + download the stock Raspberry Pi OS image
./build.sh [target] [--provision]   # bake board config; --provision adds ark-os-pi-trixie + MAVSDK
./flash.sh /dev/sdX         # write the finished image to an SD card / eMMC
```

The result is a deterministic, turnkey image: every card flashed from it is identical, boots offline, and comes up with *the carrier's hardware already configured* — and, when built with `--provision`, with ARK-OS installed too. It's the production-line analogue of `ark_jetson_kernel --provision`, but far simpler because there is no kernel to build and no NVIDIA recovery-mode flashing.

> **Status.** Not yet validated on hardware. The build runs end to end; the chroot/partition plumbing in `build.sh` is the part most likely to need tuning on a given host, and only the `pi6x-cm4` target's `config.txt` is taken verbatim from hardware docs (see [Targets](#targets)).

## Targets

A *target* is a **carrier board × compute module** pair. It decides the hostname and the `config.txt` overlays baked into the image, so one builder produces turnkey images for several boards. Pick one with `./build.sh <target>` (or set `TARGET=` in `versions.env`); the output is named `<target>-<codename>.img` (or `<target>-<codename>-ark-os.img` when built with `--provision`).

| Target | Carrier + compute module | Hostname | Status |
|---|---|---|---|
| `pi6x-cm4` *(default)* | ARK Pi6X Flow (onboard ARKV6X) + CM4 — **native** | `pi6x` | populated — `config.txt` verbatim from the flashing guide |
| `pi6x-cm5` | ARK Pi6X Flow + CM5 — caveats (TODO) | `pi6x` | **stub** — won't build yet |
| `justapi-cm4` | "Just A Pi" plain carrier + CM4 — caveats (TODO) | `pi` | **stub** — won't build yet |
| `justapi-cm5` | "Just A Pi" plain carrier + CM5 — **native** | `pi` | **stub** — won't build yet |

Each carrier has a *native* compute module (the one it was designed around) and a cross combo that works but carries hardware caveats:

> **Caveats — TODO.** Details to be filled in.
> - **`pi6x-cm5`** — the Pi6X Flow was designed for the **CM4** pinout; running a CM5 on it has hardware caveats. *(TODO: document them — CM5's RP1 also changes UART numbering and fan/GPIO handling vs CM4.)*
> - **`justapi-cm4`** — the Just-A-Pi carrier was designed around the **CM5**; running a CM4 on it has hardware caveats. *(TODO: document them.)*

Each target is a small file in `targets/`. Only `pi6x-cm4` is populated today; `pi6x-cm5`, `justapi-cm4`, and `justapi-cm5` are stubs (`TARGET_STUB=1`) that refuse to build until their specifics are filled in. To populate one, copy `targets/pi6x-cm4.target`, set `TARGET_HOSTNAME`, list the lines to comment out (`CONFIG_TXT_DISABLE`) and append (`CONFIG_TXT_APPEND`) in `config.txt`, and delete the `TARGET_STUB` line.

With `--provision`, all four targets install the **same** `ark-os-pi-trixie` deb — there is one ARK-OS build per Pi OS release, and the golden images differ only in baked configuration (hostname + `config.txt`). Choosing which services run or which configs get written per carrier is left to ARK-OS runtime logic, to be added later.

## Base OS

The image is **Raspberry Pi OS Lite — Trixie (Debian 13)**, pinned in `versions.env` (`PIOS_RELEASE` plus the image URL/sha256). This repo tracks **one base OS at a time**; there is no Bookworm base support. For an older OS, check out an older tag or branch of this repo. To move to a newer release, bump `PIOS_RELEASE` and the image URL/sha together. `config.txt` stays at `/boot/firmware/config.txt`.

The **ARK-OS payload** is built per OS release: the deb name tracks `PIOS_RELEASE` (`ark-os-pi-<codename>` → `ark-os-pi-trixie`), built by ARK-OS's Trixie CI leg against Debian 13 / `python3.13` so its bundled venv matches the base. The deb's `preinst` enforces that its codename matches the host, so the two must agree. MAVSDK is the one cross-release piece — there is no `debian13_arm64` asset, so the `debian12_arm64` build is used; it's C++ and libstdc++ is backward compatible, so it runs fine on Trixie. See [Notes / open items](#notes--open-items).

## What it bakes (vs. the manual flashing guide)

The [Pi6X Flow flashing guide](https://docs.arkelectron.com/products/flight-controller/ark-pi6x-flow/flashing-guide) walks a user through doing this by hand; the golden image does it once, at build time:

| Manual step in the guide | Handled by |
|---|---|
| Flash Raspberry Pi OS Lite (64-bit, Trixie) | `versions.env` base-image pin |
| Imager: create the `pi` user + password | `configure_target.sh` (baked account) |
| Edit `config.txt` (UART / camera / fan / GPIO overlays) | `configure_target.sh`, from the selected `targets/*.target` |
| Set the hostname (`pi6x` → `http://pi6x.local/`) | `configure_target.sh`, from the target |
| Enable SSH | `configure_target.sh` (`ENABLE_SSH=1`) |
| Install ARK-OS + enable services | `provision.sh`, with `--provision` (ark-os-pi-trixie deb + `ark-os-firstboot`) |
| Wi-Fi credentials | left to the user / the deb's first-boot hotspot (site-specific) |

## How it works

| Script | What it does |
|---|---|
| `setup.sh` | Installs host deps (`qemu-user-static`, `binfmt-support`, `parted`, `xz-utils`, `curl`), registers the `qemu-aarch64` binfmt handler, and downloads the stock Raspberry Pi OS Lite arm64 image into `downloads/` (re-fetching it if the cache doesn't match the pinned sha256). |
| `build.sh` | Resolves the target, copies the stock image to `staging/`, grows its root partition, loop-mounts it, bind-mounts `/proc /sys /dev`, runs `configure_target.sh` (and, with `--provision`, `provision.sh`) in an `arm64` chroot (emulated via qemu on an x86 host), and reports how long the build took. Produces `staging/<target>-<codename>.img` (or `…-ark-os.img` with `--provision`). |
| `configure_target.sh` | Always runs. Bakes the `pi` user, sets the hostname, applies the target's `config.txt` edits, and enables SSH. |
| `provision.sh` | The ARK-OS payload, only with `--provision`: blocks daemon starts with a `policy-rc.d` shim, then `apt-get install`s MAVSDK and the `ark-os-pi-trixie` deb and verifies them. |
| `flash.sh` | Writes `staging/*.img` to a target block device, with size/model confirmation and guards against writing to a system disk. |

Pins (base image, ARK-OS/MAVSDK versions, baked user, target) live in `versions.env`; per-board hardware config lives in `targets/`.

## Requirements

- A Linux host with `sudo`. x86_64 works (arm64 binaries run under qemu); a native arm64 host (or a Pi) works too and is faster.
- For `--provision` builds, the `ark-os-pi-trixie_<ver>_arm64.deb` from ARK-OS's Trixie build. Drop a CI-artifact deb into `downloads/` and set `ARK_OS_VERSION` in `versions.env` to its `0.0.0-<sha8>`.

## Flashing to CM4/CM5 eMMC

`flash.sh` just `dd`s to a block device, so eMMC works once the module is exposed as one: short the carrier's `BOOT`/`nRPIBOOT` jumper, plug the USB port into the host, run `rpiboot`, and the eMMC appears as `/dev/sdX`. Flash it like a card, then remove the jumper to boot normally.

## Notes / open items

- **Change the baked password** (`versions.env`) before shipping real hardware; the appliance default is `pi` / `raspberry`.
- **Only `pi6x-cm4` is populated.** The other three targets are stubs (`TARGET_STUB=1`) and refuse to build until their `config.txt` overlays are filled in from hardware docs. The two cross combos (`pi6x-cm5`, `justapi-cm4`) additionally carry hardware caveats — see [Targets](#targets).
- **ARK-OS is built natively for Trixie.** The `ark-os-pi-trixie` deb comes from ARK-OS's Trixie CI leg (Debian 13 container), so its bundled `python3.13` venv and its `Depends` match the base image. Only MAVSDK is installed cross-release: there is no `debian13_arm64` asset, so the `debian12_arm64` build is used — fine in practice because it's C++ and libstdc++ is backward compatible. (A true Trixie MAVSDK build is the one remaining nicety if upstream ever ships one.)
- **First-boot finalization.** The deb's postinst defers a few runtime-only steps (default hotspot, flight-review DB, Wi-Fi unblock) into the `ark-os-firstboot` oneshot, which the chroot install enables (a static `WantedBy=multi-user.target` symlink that works offline). A baked card finishes configuring itself on first boot, guarded by a sentinel so it runs once.
- **Per-device uniqueness is inherited.** Because we only chroot (never boot) the stock image, Pi OS's own first-boot machinery still runs on the device: SSH host keys regenerate, `/etc/machine-id` is generated, and root expands to fill the card.
