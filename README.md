# ark_pi_image (prototype)

Build a flashable **ARK-OS Raspberry Pi golden image** and write it to an SD card,
without ever opening Raspberry Pi Imager. Three steps:

```
./setup.sh      # install host tools + download the stock Raspberry Pi OS image
./build.sh      # chroot-install the ark-os-pi deb (+ MAVSDK) into a copy of it
./flash.sh /dev/sdX   # write the finished image to an SD card
```

The result is a deterministic image: every card flashed from it is identical, boots
offline, and comes up with ARK-OS already installed — the production-line analogue
of `ark_jetson_kernel --provision`, but far simpler because there is no kernel to
build and no NVIDIA recovery-mode flashing.

> **Prototype status.** This lives inside the ARK-OS repo while we iterate; it will
> move to its own `ark_pi_image` repo. It has **not** been validated on hardware
> yet. The chroot/partition plumbing in `build.sh` is the part most likely to need
> tuning on a given host.

## How it works

| Script | What it does |
|---|---|
| `setup.sh` | Installs host deps (`qemu-user-static`, `binfmt-support`, `parted`, `xz-utils`, `curl`), registers the `qemu-aarch64` binfmt handler, and downloads the stock Raspberry Pi OS Lite arm64 image into `downloads/`. |
| `build.sh` | Copies the stock image to `staging/`, grows its root partition, loop-mounts it, bind-mounts `/proc /sys /dev`, and runs `provision.sh` in an `arm64` chroot (emulated via qemu on an x86 host). Produces `staging/ark-os-pi-<ver>.img`. |
| `provision.sh` | The chroot core (mirrors `ark_jetson_kernel/provision.sh`): bakes the `pi` user, blocks daemon starts with a `policy-rc.d` shim, then `apt-get install`s MAVSDK and the `ark-os-pi` deb and verifies them. |
| `flash.sh` | Writes `staging/*.img` to a target block device, with size/model confirmation and guards against writing to a system disk. |

Pins (base image, ARK-OS/MAVSDK versions, baked user) live in `versions.env`.

## Requirements

- A Linux host with `sudo`. x86_64 works (arm64 binaries run under qemu); a native
  arm64 host (or a Pi) works too and is faster.
- The `ark-os-pi_<ver>_arm64.deb`. Until PR #68 is released, drop a CI-artifact deb
  into `downloads/` and set `ARK_OS_VERSION` in `versions.env` to its `0.0.0-<sha8>`.

## Notes / open items

- **First-boot finalization.** The deb's postinst defers a few runtime-only steps
  (default hotspot, flight-review DB, Wi-Fi unblock) out of the chroot into the
  `ark-os-firstboot` oneshot service. The chroot install enables that service (it's
  `WantedBy=multi-user.target`, a static symlink that works offline), so a baked card
  finishes configuring itself on first boot — guarded by a sentinel so it runs once.
- **Per-device uniqueness is inherited.** Because we only chroot (never boot) the
  stock image, Pi OS's own first-boot machinery still runs on the device: SSH host
  keys regenerate, `/etc/machine-id` is generated, and root expands to fill the card.
- **Change the baked password** (`versions.env`) before shipping real hardware.
