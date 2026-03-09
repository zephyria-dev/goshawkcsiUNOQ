# Raspberry Pi DSI Display Compatibility with Arduino UNO Q

## Overview

This document lists DSI displays compatible with Raspberry Pi and their support status on the Arduino UNO Q (QRB2210). Many RPi-compatible displays require kernel modules that are **NOT included** in the Arduino UNO Q kernel.

---

## Arduino UNO Q Kernel Display Driver Status

**Kernel Version**: 6.16.7-g0dd6551ae96b

### Included DSI Bridge/Panel Drivers

| Driver | Kernel Config | Status | Module |
|--------|---------------|--------|--------|
| TC358767 (DP bridge) | `CONFIG_DRM_TOSHIBA_TC358767=m` | Available | `tc358767.ko` |
| TC358768 (DSI-to-DPI) | `CONFIG_DRM_TOSHIBA_TC358768=m` | Available | `tc358768.ko` |
| ANX7625 (USB-C/DP) | `CONFIG_DRM_ANX7625=m` | Available | `anx7625.ko` |

### Missing DSI Bridge/Panel Drivers

These are NOT in the stock kernel but can be built as out-of-tree modules using `scripts/build-dsi-modules.sh`:

| Driver | Kernel Config | Required For | Build command | Status |
|--------|---------------|--------------|---------------|--------|
| **TC358762** | `CONFIG_DRM_TOSHIBA_TC358762` | **Freenove 4.3", Official RPi 7"** | `build-dsi-ondevice.sh tc358762` | **Verified** |
| **panel_dpi** | Custom (not in kernel) | Downstream DPI panel for TC358762 | `build-dsi-ondevice.sh panel_dpi` | **Verified** |
| ILI9881C | `CONFIG_DRM_PANEL_ILITEK_ILI9881C` | WaveShare 5"/7" ILI9881 panels | `build-dsi-ondevice.sh ili9881c` | Untested |
| ST7701 | `CONFIG_DRM_PANEL_SITRONIX_ST7701` | Arduino GigaDisplay, generic 480x800 | `build-dsi-ondevice.sh st7701` | Untested |
| HX8394 | `CONFIG_DRM_PANEL_HIMAX_HX8394` | Budget 720p DSI displays | `build-dsi-ondevice.sh hx8394` | Untested |
| OTM8009A | `CONFIG_DRM_PANEL_ORISETECH_OTM8009A` | STM32 Discovery displays | `build-dsi-ondevice.sh otm8009a` | Untested |
| **goodix_ts** | `CONFIG_TOUCHSCREEN_GOODIX` (patched) | **Freenove 4.3" GT911 touch** | `build-dsi-modules.sh goodix_ts` | **Patched** |

> **Note**: `goodix_ts` IS in the stock kernel (`=m`), but the stock driver requires an IRQ GPIO. The patched version in `scripts/src/goodix.c` adds `input_setup_polling()` fallback for boards where the INT pin is not Linux-accessible.

> **Note**: TC358762 is a DSI-to-DPI **bridge**, not a panel driver. It requires a downstream DPI panel driver on its `port@1`. The `panel_dpi.ko` module provides this — it reads display timings from the device tree `panel-timing` node. The original `panel-dpi.c` was removed from upstream Linux 6.16; a custom replacement is provided in `scripts/src/panel_dpi.c`.

> Note: `ILI9341` is an SPI panel driver; not relevant for the DSI connector.

---

## RPi-Compatible DSI Displays - Compatibility Matrix

### Category 1: NOT SUPPORTED (Missing Kernel Module)

These displays work on Raspberry Pi but **will NOT work** on Arduino UNO Q without building custom kernel modules.

| Display | Bridge IC | RPi Overlay | Required Module | Notes |
|---------|-----------|-------------|-----------------|-------|
| **Freenove 4.3" Touchscreen** | TC358762 | `vc4-kms-dsi-7inch` | `tc358762.ko` | Uses same bridge as RPi official |
| **Official RPi 7" Touchscreen** | TC358762 | `vc4-kms-dsi-7inch` | `tc358762.ko` | Most common RPi display |
| WaveShare 4.3" DSI LCD | TC358762 | `vc4-kms-dsi-waveshare-panel` | `tc358762.ko` | 800x480 |
| WaveShare 5" DSI LCD | ILI9881C | `vc4-kms-dsi-ili9881-5inch` | `ili9881c.ko` | 800x480 |
| WaveShare 7" DSI LCD | ILI9881C | `vc4-kms-dsi-ili9881-7inch` | `ili9881c.ko` | 800x480 |
| WaveShare 7.9" DSI LCD | ILI9881C | `vc4-kms-dsi-ili9881-7inch` | `ili9881c.ko` | 400x1280 |
| WaveShare 8" DSI LCD (C) | ILI9881C | `vc4-kms-dsi-waveshare-panel` | `ili9881c.ko` | 1280x800 |
| WaveShare 10.1" DSI LCD | ILI9881C | `vc4-kms-dsi-waveshare-panel` | `ili9881c.ko` | 1280x800 |
| WaveShare 11.9" DSI LCD | ILI9881C | `vc4-kms-dsi-waveshare-panel` | `ili9881c.ko` | 320x1480 |
| WaveShare 800x480 Touch | TC358762 | `vc4-kms-dsi-waveshare-800x480` | `tc358762.ko` | Various sizes |
| Pimoroni HyperPixel 4 | ST7701 | `vc4-kms-dpi-hyperpixel4` | `st7701.ko` | 800x480 |
| Arduino GigaDisplay | ST7701 | N/A (Arduino specific) | `st7701.ko` | Arduino's own display |
| Generic ST7701 panels | ST7701 | `vc4-kms-dsi-generic` | `st7701.ko` | Various 480x800 |
| Generic HX8394 panels | HX8394 | N/A | `hx8394.ko` | Various 720p |
| Sharp LQ070M1SX01 | LT070ME05000 | `vc4-kms-dsi-lt070me05000` | `lt070me05000.ko` | 7" 1200x1920 |

### Category 2: POTENTIALLY SUPPORTED (Need Testing)

These might work using the available TC358768 bridge if hardware is compatible:

| Display | Notes |
|---------|-------|
| Displays using TC358768 | The TC358768 driver IS available |
| Displays with simple DSI panels | May work with `panel-simple` |

### Category 3: NOT APPLICABLE (Non-DSI)

| Display Type | Interface | UNO Q Support |
|--------------|-----------|---------------|
| HDMI displays | HDMI | Yes (via ANX7625 USB-C) |
| SPI displays | SPI | Yes (fbtft/fb_ili9341) |
| DPI displays | Parallel RGB | Not on JMEDIA |

---

## Building Missing Kernel Modules

> **Use the provided scripts** — they automate all steps below:
> ```bash
> # On device:
> scripts/build-dsi-modules.sh tc358762
>
> # Cross-compile on host PC (faster):
> scripts/cross-build-dsi-modules.sh tc358762
> ```

### Kernel Source Repository

```
https://github.com/arduino/linux-qcom
```

Kernel running on device: `6.16.7-g0dd6551ae96b`

### Prerequisites

```bash
# On the Arduino UNO Q
sudo apt update
sudo apt install build-essential bc flex bison libssl-dev libelf-dev

# Get kernel headers (if packaged — try first)
sudo apt install linux-headers-$(uname -r)

# OR clone kernel source and prepare headers manually
git clone --depth=1 https://github.com/arduino/linux-qcom.git
cd linux-qcom
make ARCH=arm64 defconfig          # arduino/linux-qcom uses a single "defconfig"
make ARCH=arm64 scripts prepare modules_prepare
export KERNEL_DIR=$(pwd)
```

### Method 1: Build Single Module On-Device (Recommended)

```bash
# Build only tc358762 (or any other module)
scripts/build-dsi-modules.sh tc358762

# Verify
lsmod | grep tc358762
modinfo tc358762
```

### Method 2: Cross-Compile on Host PC (Fastest)

```bash
# Requirements on Ubuntu/Debian host
sudo apt install gcc-aarch64-linux-gnu make bc flex bison \
                 libssl-dev libelf-dev git curl

# Run cross-compile script (clones arduino/linux-qcom automatically)
scripts/cross-build-dsi-modules.sh tc358762

# Copy to target
scp /tmp/dsi-modules-cross/modules/tc358762.ko user@<uno-q-ip>:/tmp/

# On the Uno Q — install and load
ssh user@<uno-q-ip> "
  sudo cp /tmp/tc358762.ko \
    /lib/modules/\$(uname -r)/kernel/drivers/gpu/drm/bridge/
  sudo depmod -a
  sudo modprobe tc358762
"
```

---

## Freenove 4.3" Display — Complete Setup (Verified Working)

### Hardware Requirements

- Freenove 4.3" Touchscreen (DSI interface, 800x480, TC358762 + GT911)
- `tc358762.ko` + `panel_dpi.ko` built and installed
- FPC cable connected from display to Zephyria Shield DSI connector

### Shield Limitation — DISP_EN and DISP_RESET

DSI connector pins 11 (DISP_EN) and 12 (DISP_RESET) are routed through
**JMISC to the STM32 domain** — they are NOT Linux-accessible GPIOs.

| DSI Pin | Signal | JMISC Pin | STM32 GPIO | Zephyr GPIO |
|---------|--------|-----------|------------|-------------|
| 11 | DISP_EN | 11 | PI4 | 35 |
| 12 | DISP_RESET | 13 | PI6 | 37 |

Required hardware workarounds (or use Zephyr sketch `cam_dual_io.ino`):
- **DISP_EN (pin 11)**: wire to 3V3 (pin 15) on the DSI connector
- **DISP_RESET (pin 12)**: add 100 nF cap to GND + 10 kΩ pull-up to 3V3
  (RC power-on reset), or simply wire to 3V3

### Step-by-Step Setup

```bash
# 1. Build required modules (on-device)
scripts/build-dsi-ondevice.sh tc358762
scripts/build-dsi-ondevice.sh panel_dpi

# 2. Ensure modules load at boot
echo "tc358762" | sudo tee -a /etc/modules
echo "panel_dpi" | sudo tee -a /etc/modules

# 3. Compile and install the Freenove DTB
dtc -I dts -O dtb -o imola-camera-dsi-freenove.dtb \
    dts/imola-camera-dsi-freenove.dts
sudo cp imola-camera-dsi-freenove.dtb /boot/efi/dtb/qcom/

# 4. Update boot configuration
#    Edit /boot/efi/loader/entries/*.conf:
#    devicetree /dtb/qcom/imola-camera-dsi-freenove.dtb

# 5. Reboot
sudo reboot
```

### Verification

```bash
ls /dev/dri/                              # card0, renderD128
dmesg | grep -iE 'panel|tc358762|fb0'    # panel-dpi probe, fb0 registered
cat /sys/class/drm/card0-*/status         # connected
cat /sys/class/drm/card0-*/modes          # 800x480
cat /dev/urandom > /dev/fb0               # random pixels on screen
```

### What the DTS Does

The `dts/imola-camera-dsi-freenove.dts` is a **standalone DTB** (not an overlay) based on `imola-camera-shield.dts` with these targeted changes:

| Change | Reason |
|--------|--------|
| `panel-pwr` regulator (always-on 3V3) | Powers TC358762 bridge |
| `lcd-panel` node (`panel-dpi` + `panel-timing`) | Generic DPI panel with 800x480 timings |
| `panel@0` (`toshiba,tc358762`) with `ports { port@0, port@1 }` | DSI-to-DPI bridge linked to lcd-panel |
| `data-lanes = <0 1>` (was `<0 1 2 3>`) | Shield only routes 2 DSI lanes |
| ANX7625 `status = "disabled"` | Prevents sysfs duplicate on DSI bus |
| `mdss_dsi0_out` redirected to TC358762 | Connects display pipeline |
| `touchscreen@5d` on CCI I2C0 | Goodix GT911 touch via PCA9306 level-shifter |

### Touch Controller

The Freenove 4.3" display uses a **Goodix GT911** (not FT5x06).
It is connected via CCI I2C bus 0 (JMEDIA path — Linux accessible):

| Property | Value |
|----------|-------|
| Compatible | `goodix,gt911` |
| I2C address | `0x5D` (ADDR low) or `0x14` (ADDR high) |
| I2C bus | CCI I2C0 (gpio22/gpio23, via PCA9306 level-shifter) = Linux i2c-2 |
| IRQ | INT pin on STM32 domain (JMISC) — **not available to Linux** |
| Driver | **Patched** `goodix_ts.ko` with `input_setup_polling()` (17ms/60Hz) — stock driver fails without IRQ |
| Build | `scripts/build-dsi-modules.sh goodix_ts` |
| Note | Touch requires physical display connection and DISP_RESET |

> **Known Issue**: CCI I2C bus 0 shares gpio22/gpio23 with Camera 0 (J4). If Camera 0 is faulted or holding the bus low, all devices on CCI bus 0 time out (`master 0 queue 0 timeout`), including the GT911. Disconnect Camera 0 to isolate.

> **I2C Address Latching**: The GT911 latches its I2C address on the RESET rising edge. INT must be driven LOW by the MCU firmware before RESET is released for address 0x5D. If INT floats, the address may latch to 0x14.

---

## Alternative Displays That WOULD Work

If you want to avoid building kernel modules, consider these alternatives:

### Option 1: HDMI Display via USB-C

The ANX7625 driver IS included. Use USB-C to HDMI adapter and any HDMI display.

### Option 2: SPI Display (Small)

SPI displays using ILI9341/ST7789 are supported via fbtft framework:
- 2.4" - 3.5" SPI TFT displays
- Slower refresh rate but no kernel rebuild needed

### Option 3: Displays Using TC358768

The TC358768 driver IS available. Find displays using this bridge chip.

---

## Kernel Module Request

Consider requesting Arduino to include these modules in future kernel releases:

1. **tc358762.ko** - Required for Official RPi display and most RPi DSI displays
2. **ili9881c.ko** - Required for WaveShare 5"/7" displays
3. **st7701.ko** - Required for GigaDisplay

Arduino linux-qcom repository: https://github.com/arduino/linux-qcom

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Feb 2026 | Initial RPi display compatibility guide |
| 1.1 | Feb 2026 | Correct kernel repo (arduino/linux-qcom); add build scripts reference; confirmed Freenove GT911 touch IC and JMISC domain limitations |
| 2.0 | Mar 2026 | Freenove 4.3" verified working; added panel_dpi module; TC358762 port@1 requirement; step-by-step verified instructions |
| 2.1 | Mar 2026 | GT911 touch: patched goodix_ts with polling mode; CCI bus 0 sharing with camera 0; I2C address latching sequence; known bus timeout issue |
