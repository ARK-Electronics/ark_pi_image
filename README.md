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

### ARK Hadron Adapter on the Just A Pi

The `justapi-cm5` image carries the driver (`ov64b40`, built with DKMS) and overlay for the FLIR Hadron 640R's visible camera.

- **Cabling:** the CSI ribbon goes to CAM1 (J2) and the USB to the USB 2.0 JST-GH. J3 goes to the UART2 connector with a straight 6-pin JST-GH cable, which puts the adapter's SCL and SDA on GPIO6 and GPIO7.
- **`config.txt`:** in `/boot/firmware/config.txt`, change `dtoverlay=imx708,cam0` to `dtoverlay=ov64b40,cam0`, change `dtoverlay=uart2,ctsrts` to `dtoverlay=uart2`, and uncomment `dtoverlay=i2c-gpio,i2c_gpio_sda=7,i2c_gpio_scl=6,bus=7`. UART2 keeps TX and RX.
- **CAM2 (J1):** the Hadron works there too. Keep `dtoverlay=imx708,cam0` and change `dtoverlay=imx708` to `dtoverlay=ov64b40`. The carrier ties CAM2's pin 17 high, so the Hadron's reset is always released. CAM2 has no pin 18, so the Pi can't read the sync pulses there.
- **Visible camera:** 2304x1728 RAW10 (RGGB) at 20 fps on two lanes at 799.2 Mbps. The Pi 5's CSI-2 receiver takes at most 1.5 Gbps per lane, which rules out the Jetson driver's modes; this one comes from the Ingenic T40 SDK's table. libcamera doesn't support the sensor (no camera helper or tuning file), so `rpicam-*` and ARK-OS's RTSP server don't see it. Capture raw frames with V4L2; device numbers depend on probe order, so look them up by name:

  ```bash
  for m in /dev/media*; do media-ctl -d $m -p | grep -q ': ov64b40 ' && MEDIA=$m; done
  SENSOR=$(media-ctl -d $MEDIA -e "$(media-ctl -d $MEDIA -p | sed -n 's/^- entity [0-9]*: \(ov64b40 [^ ]*\) .*/\1/p')")
  VIDEO=$(media-ctl -d $MEDIA -e rp1-cfe-csi2_ch0)
  F='fmt:SRGGB10_1X10/2304x1728 field:none colorspace:raw xfer:none ycbcr:601 quantization:full-range'
  media-ctl -d $MEDIA -l '"csi2":4 -> "rp1-cfe-csi2_ch0":0 [1]'
  media-ctl -d $MEDIA -V "\"csi2\":0 [$F], \"csi2\":4 [$F]"
  v4l2-ctl -d $VIDEO --set-fmt-video=width=2304,height=1728,pixelformat=pRAA
  v4l2-ctl -d $VIDEO --stream-mmap --stream-count=20 --stream-to=frames.raw
  ```

  Exposure (lines), analogue gain (0x100 = 1x), vertical blanking (998 for 20 fps, down to 128 for 29.4 fps) and a colour-bar test pattern are controls on the sensor's subdevice: `v4l2-ctl -d $SENSOR -l`. To reload the driver, reboot: unloading and reloading a sensor module oopses the Pi kernel's CSI-2 receiver driver (`rp1-cfe`).
- **Thermal camera:** the Boson is a UVC camera ("FLIR Video") at 30 fps.
- **IMU:** the adapter's ICM-45686 is at `0x68` on `/dev/i2c-7`; the Hadron's own IMU answers at `0x28`.
- **Reset:** CAM1 pin 17 is the Hadron's reset, which its Boson shares. The overlay holds it released for good, so no camera driver powering down resets the Boson.
- **Frame sync:** with R12 fitted, the IMU tags the Boson's sync pulses. With R11 fitted, the pulses also reach CAM1 pin 18 (GPIO35), which the Pi only reads; apart from the CM5 holding it low during boot, nothing on the Pi drives it.
- **R11 and the CM5's pull-up:** the CM5 pulls GPIO35 up to 3.3 V through 15 kΩ on the module, and no setting removes it. The Boson holds the sync line low at power-on and pulses it as sync master, so in normal use the pull-up only loads its output. The line rises above the Hadron's 2.1 V input limit only when nothing drives it: with the Boson as a sync slave, or with the Hadron unpowered while the CM5 is on. About 0.1 to 0.2 mA then flows into the Hadron's sync pin. Staying in spec in those cases would need a divider or level translator on the adapter.

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
| `TARGET_DRIVERS` | Drivers from `drivers/` to build with DKMS, with their overlays |

## Releases

Each carrier has its own tag: `pi6x-v<major>.<minor>.<patch>` or `just-a-pi-v<major>.<minor>.<patch>`.

1. Pushing the tag runs **Release**, which builds every `targets/<carrier>-*.target` (`just-a-pi` builds `justapi-*`) and keeps the compressed images as run artifacts.
2. Bench-test those files: `gh run download <run-id>`.
3. Run **Publish to downloads.arkelectron.com** with the tag. It uploads to `downloads.arkelectron.com/pi/<carrier>/<version>/` and makes that version `latest/`.

Release can also run by hand on a branch to build test images; those runs are never published.
