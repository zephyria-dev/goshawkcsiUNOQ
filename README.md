# GosHawk Hat Shield - Camera Integration Guide

This project concentrates all information available to add in Linux device tree of Arduino UNO Q, all devices handled by GosHawk Hat Shield. 

Uno Q is a relatively new Single Board Computer (SBC) with two domains: a Microprocessor (MPU) able to run Linux (QRB2210 SoC) and a Microcontroller (MCU) that runs Zephyr (STM32U585). These two domains are interconnected and can handle IPC efficiently.

## Table of Contents

1. [Devices Handled by GosHawk Hat Shield](#devices-handled-by-zephyria-shield)
2. [Camera Hardware Analysis](#camera-hardware-analysis)
3. [Device Tree Configuration](#device-tree-configuration)
4. [Configuring Cameras in Linux](#configuring-cameras-in-linux)
5. [Image and Video Capture](#image-and-video-capture)
6. [Troubleshooting](#troubleshooting)
7. [DSI Display Integration](#dsi-display-integration)
8. [Audio Integration](#audio-integration)
9. [Touchscreen (GT911)](#touchscreen-gt911)
10. [References](#references)

---
Announcement: CSI camera functions are working. A updated patch for DSI screens is on the way!
---

## Devices Handled by GosHawk Hat Shield

- 2 CSI cameras through UNO Q JMEDIA/JMISC connector
- 1 DSI display through UNO Q JMEDIA/JMISC connector
- 1 audio output 
- 1 mic input

### Cameras Supported

- IMX219 Camera (RPi Camera v2)

---

## Camera Hardware Analysis

### Shield Design Limitation

**Current design (not ideal):**
```
Camera ENABLE → JMISC → STM32 MCU domain (NOT Linux-controllable)
```

**Expected design:**
```
Camera ENABLE → JMEDIA → QRB2210 SoC domain (Linux-controllable GPIO)
```

**Workaround:** Jumper CSI pin 11 to pin 15 (3.3V) to permanently enable camera power.

Alternatively, the STM32 Zephyr firmware can control these pins — see `arduino_ide/cam_dual_io/cam_dual_io.ino` for the reference sketch that enables all devices at boot.

### Shield Schematic Analysis

#### J4 - CSI0 Connector (Camera 1)

| J4 Pin | Signal | Source | Purpose |
|--------|--------|--------|---------|
| 1, 4, 7, 10 | GND | — | Ground |
| 2-3 | CSI0_DATA_LN0_N/P | JMEDIA | CSI Data Lane 0 ✓ |
| 5-6 | CSI0_DATA_LN1_N/P | JMEDIA | CSI Data Lane 1 ✓ |
| 8-9 | CSI0_CLK_N/P | JMEDIA | CSI Clock Lane ✓ |
| 11 | CAM0_EN | JMISC pin 12 (STM32 PE7) | **ENABLE** — tie to 3V3 or Zephyr GPIO 36 |
| 12 | CAM0_LED_EN | JMISC pin 12 (STM32 PE7) | Camera board LED (shared with EN on CAM0) |
| 13 | CCI_I2C_SCL0 | via PCA9306 | I2C Clock ✓ |
| 14 | CCI_I2C_SDA0 | via PCA9306 | I2C Data ✓ |
| 15 | VCC_3V3 | JMEDIA | Power (always-on) ✓ |

#### J3 - CSI1 Connector (Camera 2)

| J3 Pin | Signal | Source | Purpose |
|--------|--------|--------|---------|
| 1, 4, 7, 10 | GND | — | Ground |
| 2-3 | CSI1_DATA_LN0_N/P | JMEDIA | CSI Data Lane 0 ✓ |
| 5-6 | CSI1_DATA_LN1_N/P | JMEDIA | CSI Data Lane 1 ✓ |
| 8-9 | CSI1_CLK_N/P | JMEDIA | CSI Clock Lane ✓ |
| 11 | CAM1_EN | JMISC pin 23 (STM32 PA8) | **ENABLE** — tie to 3V3 or Zephyr GPIO 47 |
| 12 | CAM1_LED_EN | JMISC pin 25 (STM32) | Camera board LED (Zephyr GPIO 49) |
| 13 | CCI_I2C_SCL1 | via PCA9306 | I2C Clock ✓ |
| 14 | CCI_I2C_SDA1 | via PCA9306 | I2C Data ✓ |
| 15 | VCC_3V3 | JMEDIA | Power (always-on) ✓ |

> **Note:** The RPi Camera v2 (IMX219) has **no RESET pin on the FPC connector**. The sensor XCLR (reset) is tied HIGH on the camera module PCB via a pull-up resistor. CSI pin 12 is LED_EN (controls the small red LED on the camera board), not a reset pin.

### RPi Camera v2 Analysis

**Critical discovery from camera schematic:**

The RPi Camera v2 has an onboard 24MHz oscillator and does NOT require the external MCLK **signal** from the host. However, the Linux IMX219 driver **validates** the clock configuration and requires seeing 24MHz configured in the device tree, even though the actual clock comes from the camera's internal oscillator.

**Camera power-on sequence:**
1. Host asserts **ENABLE** (CSI pin 11) HIGH
2. Enables onboard LDOs: U1 (1.8V) and U2 (2.8V)
3. Onboard oscillator starts providing MCLK to IMX219
4. Sensor XCLR is held HIGH by on-board pull-up (always out of reset)
5. Sensor powers up, I2C interface becomes responsive

> **Note:** There is no separate RESET pin on the CSI connector. CSI pin 12 is **LED_EN** (camera board LED indicator), not sensor reset. The IMX219 XCLR is managed internally on the camera module PCB.

---

## Device Tree Configuration

### Differences from Raspberry Pi

| Component | Raspberry Pi 5 | Arduino UNO Q (QRB2210) |
|-----------|---------------|------------------------|
| **CSI Receiver** | Unicam (Broadcom) | CAMSS (Qualcomm) |
| **Device Tree Structure** | `&cam0`, `&cam1` | `&csiphy0`, `&csid0`, `&vfe0` |
| **I2C for camera** | Dedicated I2C | CCI (Camera Control Interface) |
| **Camera Driver** | `ov5647.ko`, `imx219.ko` | `imx219.ko` |
| **Overlay System** | `/boot/firmware/overlays/` | `/boot/efi/dtb/qcom/` |
| **Boot Config** | `config.txt` with `dtoverlay=` | Loader entry with `devicetree` |

### Camera Pipeline Architecture

```
Camera Sensor (IMX219)
    ↓ [MIPI CSI-2, 2 lanes]
CSIPHY (Physical Layer)
    ↓
CSID (CSI Decoder)
    ↓
VFE (Video Front End)
    ↓
/dev/videoX
```

###### As reference: Raspberry Pi 5 Camera Pipeline:
```
Camera Sensor (OV5647)
    ↓ [MIPI CSI-2]
Unicam (CSI Receiver)
    ↓
/dev/video0
```

### GCC Clock IDs (QCM2290)

| Clock Name | ID (Dec) | ID (Hex) | Purpose |
|------------|----------|----------|---------|
| GCC_CAMSS_MCLK0_CLK | 37 | 0x25 | Camera 1 gate clock |
| GCC_CAMSS_MCLK0_CLK_SRC | 38 | 0x26 | Camera 1 source clock |
| GCC_CAMSS_MCLK1_CLK | 39 | 0x27 | Camera 2 gate clock |
| GCC_CAMSS_MCLK1_CLK_SRC | 40 | 0x28 | Camera 2 source clock |

### Camera 1 Device Tree Node

```dts
/* Power regulator - always-on since ENABLE is hardware-controlled */
cam0-pwr {
    compatible = "regulator-fixed";
    regulator-name = "cam0-pwr";
    phandle = <0xfb>;
    regulator-always-on;
    regulator-boot-on;
};

/* Sensor node inside CCI i2c-bus@0 */
sensor@10 {
    compatible = "sony,imx219";
    reg = <0x10>;
    
    /* Power supplies */
    VANA-supply = <0xfb>;
    VDIG-supply = <0xfb>;
    VDDL-supply = <0xfb>;
    
    /* Clock configuration - CRITICAL: use correct IDs */
    clocks = <0x26 0x25>;              /* GCC (phandle), MCLK0_CLK (37) */
    clock-names = "xclk";
    assigned-clocks = <0x26 0x26>;     /* GCC, MCLK0_CLK_SRC (38) */
    assigned-clock-rates = <24000000>; /* 24 MHz */
    
    /* CSI-2 port */
    port {
        endpoint {
            phandle = <0xf9>;
            remote-endpoint = <0xfc>;  /* Link to csiphy0 */
            data-lanes = <0x01 0x02>;
            clock-lanes = <0x00>;
            link-frequencies = <0x00 0x1b2e0200>; /* 456 MHz */
        };
    };
};
```

### Camera 2 Device Tree Node

```dts
/* Power regulator for Camera 2 */
cam1-pwr {
    compatible = "regulator-fixed";
    regulator-name = "cam1-pwr";
    phandle = <0xfd>;
    regulator-always-on;
    regulator-boot-on;
};

/* Sensor node inside CCI i2c-bus@1 */
i2c-bus@1 {
    reg = <0x01>;
    #address-cells = <0x01>;
    #size-cells = <0x00>;
    clock-frequency = <1000000>;
    
    sensor@10 {
        compatible = "sony,imx219";
        reg = <0x10>;
        
        /* Power supplies */
        VANA-supply = <0xfd>;
        VDIG-supply = <0xfd>;
        VDDL-supply = <0xfd>;
        
        /* Clock configuration - Camera 2 uses MCLK1 */
        clocks = <0x26 0x27>;              /* GCC, MCLK1_CLK (39) */
        clock-names = "xclk";
        assigned-clocks = <0x26 0x28>;     /* GCC, MCLK1_CLK_SRC (40) */
        assigned-clock-rates = <24000000>; /* 24 MHz */
        
        /* CSI-2 port - connects to csiphy1 */
        port {
            cam1_endpoint: endpoint {
                remote-endpoint = <&csiphy1_ep>;
                data-lanes = <0x01 0x02>;
                clock-lanes = <0x00>;
                link-frequencies = /bits/ 64 <456000000>;
            };
        };
    };
};
```

### CSIPHY1 Configuration for Camera 2

```dts
/* Inside camss@5c11000 node, add csiphy1 port */
port@1 {
    reg = <0x01>;
    csiphy1_ep: endpoint {
        remote-endpoint = <&cam1_endpoint>;
        clock-lanes = <0x07>;
        data-lanes = <0x00 0x01>;
    };
};
```

### Complete Steps to Add Camera 2

1. **Decompile current DTB:**
   ```bash
   cd ~/inspection
   dtc -I dtb -O dts -o camera-dual.dts /boot/efi/dtb/qcom/qrb2210-arduino-imola-camera-shield.dtb
   ```

2. **Add cam1-pwr regulator** (in root node, near cam0-pwr)

3. **Add i2c-bus@1** inside cci@5c1b000 node with sensor@10

4. **Add port@1** inside camss@5c11000 for csiphy1

5. **Compile and install:**
   ```bash
   dtc -I dts -O dtb -o camera-dual.dtb camera-dual.dts
   sudo cp camera-dual.dtb /boot/efi/dtb/qcom/qrb2210-arduino-imola-camera-dual.dtb
   sudo sed -i 's/camera-shield.dtb/camera-dual.dtb/' /boot/efi/loader/entries/*.conf
   sudo reboot
   ```

6. **Hardware:** Jumper J3 CSI pin 11 to pin 15 (3.3V) for Camera 2 ENABLE

---

## Configuring Cameras in Linux

### Automatic Camera Setup (Recommended)

Use the `camera-setup.sh` script to automatically detect cameras, identify `/dev/videoX` devices, and configure the media pipeline:

```bash
# Detect and configure all connected cameras
scripts/camera-setup.sh

# Detect, configure, and capture one frame from each camera
scripts/camera-setup.sh capture

# Continuous stream from a specific camera
scripts/camera-setup.sh stream CAM0
scripts/camera-setup.sh stream CAM1
```

The script:
- Parses `media-ctl -p` to find all IMX219 sensors
- Traces ENABLED links through the pipeline to find `/dev/videoX` for each
- Assigns stable names: CAM0 = lower I2C bus (J4), CAM1 = higher I2C bus (J3)
- Configures all pipeline element formats automatically

> **Note**: The CAMSS optional-sensor patch (`scripts/build-camss-patched.sh`) is required for the camera subsystem to work when one or both cameras are connected. Without it, ALL DT-declared sensors must be present or `/dev/media0` never appears.

### Verify Camera Detection

```bash
# Check I2C detection (0x10 = IMX219)
sudo i2cdetect -y 0  # Camera 1 on CCI bus 0
sudo i2cdetect -y 1  # Camera 2 on CCI bus 1

# Check dmesg for driver
dmesg | grep -i imx219

# List video devices
v4l2-ctl --list-devices

# Show media pipeline
media-ctl -d /dev/media0 -p
```

### Manual Pipeline Configuration

If you prefer to configure manually (or camera-setup.sh is not available):

#### Camera on CCI bus 1 (typical single-camera setup)

The I2C adapter number may vary — check `media-ctl -p` for the actual sensor name (e.g. `imx219 2-0010`).

```bash
# Set all pipeline elements
media-ctl -d /dev/media0 --set-v4l2 '"imx219 2-0010":0[fmt:SRGGB10_1X10/1920x1080]'
media-ctl -d /dev/media0 --set-v4l2 '"msm_csiphy1":0[fmt:SRGGB10_1X10/1920x1080]'
media-ctl -d /dev/media0 --set-v4l2 '"msm_csiphy1":1[fmt:SRGGB10_1X10/1920x1080]'
media-ctl -d /dev/media0 --set-v4l2 '"msm_csid0":0[fmt:SRGGB10_1X10/1920x1080]'
media-ctl -d /dev/media0 --set-v4l2 '"msm_csid0":1[fmt:SRGGB10_1X10/1920x1080]'
media-ctl -d /dev/media0 --set-v4l2 '"msm_vfe0_rdi0":0[fmt:SRGGB10_1X10/1920x1080]'
media-ctl -d /dev/media0 --set-v4l2 '"msm_vfe0_rdi0":1[fmt:SRGGB10_1X10/1920x1080]'

# Capture from /dev/video0
timeout 10 v4l2-ctl -d /dev/video0 \
    --set-fmt-video=width=1920,height=1080,pixelformat=pRAA \
    --stream-mmap --stream-count=1 --stream-to=capture.raw
```

#### Dual-camera pipeline

With two cameras, the pipeline routes are assigned dynamically. Use `camera-setup.sh` or check `media-ctl -p` to identify which csiphy/csid/vfe each sensor connects to. The `/dev/videoX` device differs depending on which cameras are present.

### Set Exposure and Gain

```bash
# Find sensor subdev
media-ctl -d /dev/media0 -p | grep -B2 "imx219"

# Set exposure (adjust as needed)
v4l2-ctl -d /dev/v4l-subdev12 --set-ctrl=exposure=5000
v4l2-ctl -d /dev/v4l-subdev12 --set-ctrl=analogue_gain=400

# List all controls
v4l2-ctl -d /dev/v4l-subdev12 -l
```

---

## Image and Video Capture

### Capture Raw Image

```bash
# Using camera-setup.sh (recommended — handles device detection automatically):
scripts/camera-setup.sh capture

# Or manually — use the /dev/videoX identified by camera-setup.sh or media-ctl -p:
timeout 10 v4l2-ctl -d /dev/video0 --set-fmt-video=width=1920,height=1080,pixelformat=pRAA \
    --stream-mmap --stream-count=1 --stream-to=camera.raw

# Check file size (should be ~2.5MB for 1920x1080 10-bit)
ls -la *.raw
```

### Convert Raw to JPEG

```python
#!/usr/bin/env python3
# save as convert_raw.py
import numpy as np
import sys

width = 1920
height = 1080
input_file = sys.argv[1] if len(sys.argv) > 1 else "capture.raw"
output_file = input_file.replace('.raw', '.jpg')

# Read packed 10-bit data
packed = np.fromfile(input_file, dtype=np.uint8)
print(f"Read {len(packed)} bytes, Min:{packed.min()}, Max:{packed.max()}, Mean:{packed.mean():.1f}")

# Unpack 10-bit MIPI to 16-bit
bytes_per_row = (width * 10) // 8
packed = packed[:bytes_per_row * height].reshape(height, bytes_per_row)

img = np.zeros((height, width), dtype=np.uint16)
for y in range(height):
    for x in range(0, width, 4):
        i = (x * 10) // 8
        b0, b1, b2, b3, b4 = packed[y, i:i+5]
        img[y, x]     = (b0 << 2) | ((b4 >> 0) & 0x03)
        img[y, x + 1] = (b1 << 2) | ((b4 >> 2) & 0x03)
        img[y, x + 2] = (b2 << 2) | ((b4 >> 4) & 0x03)
        img[y, x + 3] = (b3 << 2) | ((b4 >> 6) & 0x03)

print(f"Unpacked 10-bit: Min:{img.min()}, Max:{img.max()}, Mean:{img.mean():.1f}")

# Stretch contrast
img_min, img_max = img.min(), img.max()
if img_max > img_min:
    img_stretched = ((img - img_min) * 1023 / (img_max - img_min)).astype(np.uint16)
else:
    img_stretched = img

# Convert to 8-bit
img8 = (img_stretched >> 2).astype(np.uint8)

# Debayer using OpenCV
try:
    import cv2
    bgr = cv2.cvtColor(img8, cv2.COLOR_BAYER_RG2BGR)
    bgr_bright = cv2.convertScaleAbs(bgr, alpha=2.0, beta=30)
    cv2.imwrite(output_file, bgr_bright)
    print(f"Saved {output_file}")
except ImportError:
    print("Install OpenCV: pip install opencv-python --break-system-packages")
```

Usage:
```bash
python3 convert_raw.py camera1.raw
python3 convert_raw.py camera2.raw
```

---

## Troubleshooting

### Error: "xclk frequency not supported: 19200000 Hz"

**Cause:** Wrong clock ID in device tree - using gate clock instead of source clock for `assigned-clocks`.

**Solution:** Ensure device tree uses:
```dts
clocks = <&gcc 37>;              /* Gate clock for driver */
assigned-clocks = <&gcc 38>;     /* Source clock for rate setting */
assigned-clock-rates = <24000000>;
```

### Error: "Error reading reg 0x0000: -6" (ENXIO)

**Cause:** Camera not powered or ENABLE pin not HIGH.

**Solution:**
1. Verify ENABLE: CSI pin 11 tied to 3V3, or Zephyr sketch running (`cam_dual_io.ino`)
2. Check FFC cable is properly seated
3. Test camera on a Raspberry Pi to verify it works

### Error: "Broken pipe" or streaming hangs

**Cause:** Media pipeline not configured or format mismatch.

**Solution:**
```bash
# Configure full pipeline before capture
media-ctl -d /dev/media0 --set-v4l2 '"imx219 0-0010":0[fmt:SRGGB10_1X10/1920x1080]'
# ... (all pipeline elements)

# Use 10-bit format, not 8-bit
v4l2-ctl -d /dev/video0 --set-fmt-video=pixelformat=pRAA  # Not RGGB
```

### Error: "VFE0: Input data violation"

**Cause:** Format mismatch between sensor output and pipeline configuration.

**Solution:** Use native 10-bit format throughout:
```bash
# IMX219 outputs SRGGB10_1X10, not SRGGB8_1X8
media-ctl -d /dev/media0 --set-v4l2 '"imx219 0-0010":0[fmt:SRGGB10_1X10/1920x1080]'
```

### Camera detected but image is black

**Possible causes:**
1. Lens cap still on camera
2. Camera pointing at dark scene
3. Exposure too low

**Solution:**
```bash
# Set maximum exposure for testing
v4l2-ctl -d /dev/v4l-subdev12 --set-ctrl=exposure=10000
v4l2-ctl -d /dev/v4l-subdev12 --set-ctrl=analogue_gain=800

# Point camera at bright light source
# Verify raw data has content:
hexdump -C capture.raw | head -10
```

---

## Linux Diagnostic Commands

### Device Tree

```bash
# Decompile DTB to DTS
dtc -I dtb -O dts -o output.dts input.dtb

# Compile DTS to DTB
dtc -I dts -O dtb -o output.dtb input.dts

# View live device tree
ls /proc/device-tree/
```

### I2C

```bash
# List I2C buses
ls /dev/i2c-*

# Scan for devices
sudo i2cdetect -y 0

# List I2C device names
cat /sys/bus/i2c/devices/*/name
```

### Clocks

```bash
# Check clock rates
sudo cat /sys/kernel/debug/clk/gcc_camss_mclk0_clk_src/clk_rate

# Check if clock is enabled
sudo cat /sys/kernel/debug/clk/gcc_camss_mclk0_clk/clk_enable_count

# View clock tree
sudo cat /sys/kernel/debug/clk/clk_summary | grep -i cam
```

### Video

```bash
# List video devices
ls -la /dev/video* /dev/media*

# List V4L2 devices
v4l2-ctl --list-devices

# Show supported formats
v4l2-ctl -d /dev/video0 --list-formats-ext

# Show media pipeline
media-ctl -d /dev/media0 -p
```

### Driver Management

```bash
# Reload driver
sudo modprobe -r imx219
sudo modprobe imx219

# Check dmesg
dmesg | grep -i imx219
```

---

## DSI Display Integration

### Documentation

See the dedicated display documentation:

- **[DSI-DISPLAY-GUIDE.md](docs/DSI-DISPLAY-GUIDE.md)** - Display subsystem architecture, device tree configuration, and Freenove 4.3" verified setup
- **[RPI-DISPLAY-COMPATIBILITY.md](docs/RPI-DISPLAY-COMPATIBILITY.md)** - RPi display compatibility matrix and missing kernel modules

### Quick Status

| Display | Bridge IC | Kernel Support | Status |
|---------|-----------|----------------|--------|
| Freenove 4.3" | TC358762 | Out-of-tree modules | **VERIFIED WORKING** |
| RPi Official 7" | TC358762 | Out-of-tree modules | Should work (same bridge) |
| WaveShare ILI9881 | ILI9881C | Out-of-tree modules | Untested |
| Arduino GigaDisplay | ST7701 | Out-of-tree modules | Untested |

### Display Pipeline (Verified Working)

```
DPU @5e01000 → DSI @5e94000 → TC358762 (DSI-to-DPI bridge)
                                    → panel-dpi (generic DPI panel)
                                        → 800×480 framebuffer
```

Verified output:
- `/dev/dri/card0`, `/dev/dri/renderD128`
- `/dev/fb0` — `msmdrmfb` 800×480 @ 32bpp
- Connector status: `connected`

### Building Display Modules

```bash
# On-device — build all display modules:
scripts/build-dsi-ondevice.sh all

# Or build a specific module:
scripts/build-dsi-ondevice.sh tc358762
scripts/build-dsi-ondevice.sh panel_dpi

# Cross-compile on host PC:
scripts/cross-build-dsi-modules.sh all
```

Required modules for Freenove 4.3": `tc358762.ko` + `panel_dpi.ko`

See [DSI-DISPLAY-GUIDE.md](docs/DSI-DISPLAY-GUIDE.md#freenove-43-display--verified-working) for complete setup instructions.

---

## Audio Integration

### Documentation

See **[AUDIO-INTEGRATION-GUIDE.md](docs/AUDIO-INTEGRATION-GUIDE.md)** for complete audio architecture and reference.

### Quick Setup

```bash
scripts/configure-audio.sh              # Configure routing + 80% volume + 60% mic
scripts/configure-audio.sh volume 50    # Adjust headphone volume (0–100%)
scripts/configure-audio.sh mic-gain 80  # Adjust microphone gain (0–100%)
scripts/configure-audio.sh status       # Show current configuration
scripts/configure-audio.sh test         # Quick playback test
```

### DSI Panel Users — HDMI Audio DAI Fix

When using the Freenove DSI display DTB (ANX7625 disabled), the sound card fails with:
```
snd-sm8250: HDMI/I2S Playback: codec dai not found
```
**Fix**: The `hdmi-i2s-dai-link` node must have `status = "disabled"` in the Freenove DTS. This is already applied in the current `dts/imola-camera-dsi-freenove.dts`.

### Hardware — Shield Pin Mapping

| Function | Signal | JMISC Pin |
|----------|--------|-----------|
| Mic Negative | MIC2_INM | 31 |
| Mic Positive | MIC2_INP | 29 |
| Mic Bias | MIC2_BIAS | 33 |
| Headphone Ref | HPH_REF | 40 |
| Headphone Left | HPH_L | 36 |
| Headphone Right | HPH_R | 38 |

### Audio Pipeline Architecture

The PM4125 codec uses a Qualcomm QDSP6 pipeline with SoundWire — there are **no traditional "Volume" or "Mic" mixer controls**. Instead, hundreds of routing switches connect the DSP to the codec hardware. The `configure-audio.sh` script handles all routing automatically.

```
Playback:  Q6ASM → RX_CODEC_DMA_RX_0 → LPASS RX Macro → Interpolators → DEM → RDAC → HPH L/R
Capture:   AMIC2 → ADC2 → SoundWire TX → TX Macro DEC0 → TX_CODEC_DMA_TX_3 → Q6ASM → MultiMedia1
```

**Key controls** (set by `configure-audio.sh`):

| Control | Range | Purpose |
|---------|-------|---------|
| `RX_RX0 Digital` / `RX_RX1 Digital` | 0–84 (84 = 0dB) | Headphone volume (L/R) |
| `TX_DEC0` | 0–20 (+20dB max) | Microphone decimator gain |
| `HPHL Switch` / `HPHR Switch` | 0/1 | Headphone enable |
| `HPHL_RDAC Switch` / `HPHR_RDAC Switch` | 0/1 | DAC enable |
| `RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1` | 0/1 | DSP → codec playback route |
| `MultiMedia1 Mixer TX_CODEC_DMA_TX_3` | 0/1 | Codec → DSP capture route |

### Testing

```bash
# Playback test
speaker-test -c 2 -t sine -f 440 -l 2

# Record + playback
arecord -d 5 -r 48000 -c 2 -f S16_LE -t wav /tmp/test.wav && aplay /tmp/test.wav
```

### Audio Diagnostics

```bash
cat /proc/asound/cards                              # List sound cards
dmesg | grep -iE 'adsp|q6afe|soundwire|pm4125'     # Check codec probe
lsmod | grep -iE 'snd|q6|soundwire'                # Check audio modules
scripts/configure-audio.sh status                    # Show routing status
```

### Known Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| No sound card found | HDMI DAI link references disabled ANX7625 | Use Freenove DTS with `hdmi-i2s-dai-link { status = "disabled"; }` |
| `Write error: -5` on playback | Routing not configured | Run `scripts/configure-audio.sh` first |
| No "Volume"/"Mic" in alsamixer | Normal — PM4125 uses routing controls | Press **F5** (All) in alsamixer; use `configure-audio.sh volume/mic-gain` |
| Very quiet recording | Decimator gain too low | `scripts/configure-audio.sh mic-gain 100` |
| Underrun errors | System load or DSP timing | Reduce buffer: `speaker-test --period-size 4096 --buffer-size 16384` |

---

## Touchscreen (GT911)

The Freenove 4.3" display includes a **Goodix GT911** capacitive touch controller connected via CCI I2C bus 0.

### Status: Patched Driver Ready — Awaiting Hardware Fix

| Item | Detail |
|------|--------|
| IC | Goodix GT911 |
| I2C bus | CCI I2C0 (gpio22/gpio23) = Linux **i2c-2** |
| I2C address | 0x5D (ADDR latched LOW) or 0x14 (ADDR latched HIGH) |
| INT pin | STM32 domain (JMISC → Zephyr GPIO 35) — **not Linux-accessible** |
| RESET pin | Shared with DISP_RESET (JMISC → Zephyr GPIO 37) |
| Driver | **Patched** `goodix_ts.ko` with polling mode (replaces stock) |

### Issue: Stock Driver Requires IRQ

The upstream `goodix_ts.ko` (`CONFIG_TOUCHSCREEN_GOODIX=m`) calls `devm_request_threaded_irq()` unconditionally. Since the GT911 INT pin is on the STM32 domain, `client->irq == 0` and the probe fails.

### Fix: Patched Driver with Polling Mode

A patched `goodix.c` in `scripts/src/` adds `input_setup_polling()` fallback when no IRQ is available (17ms interval / ~60Hz):

```bash
# Build (on-device or cross-compile)
scripts/build-dsi-modules.sh goodix_ts

# Install — replaces stock module
KVER=$(uname -r)
sudo cp /tmp/dsi-modules-build/goodix_ts/goodix_ts.ko \
  /lib/modules/$KVER/kernel/drivers/input/touchscreen/
sudo depmod -a
sudo modprobe goodix_ts
```

### Current Blocker: CCI Bus 0 Hardware Timeout

CCI I2C master 0 reports `queue 0 timeout` on every transaction — no device responds on the bus (not even Camera 0). This affects both GT911 and Camera 0 since they share the same I2C lines:

```
gpio22/23 → JMEDIA 51/53 → PCA9306 level-shifter → DSI connector pins 13/14
                                                   → J4 CSI connector I2C
```

**Diagnosis**: `sudo i2cdetect -y 2` shows all `--` (no ACK from any address). `dmesg` shows `i2c-qcom-cci: master 0 queue 0 timeout`. CCI master 1 (bus 3, Camera 1) works fine.

**Hardware checks needed** (requires physical access):
1. Disconnect Camera 0 (J4) — a faulted camera can hold SDA/SCL low
2. Verify DSI FPC cable seating (pins 13/14 = I2C)
3. Check PCA9306 level-shifter has VREF on both sides

### MCU Firmware — GT911 Reset Sequence

The GT911 latches its I2C address on the RESET rising edge based on INT pin state. The MCU firmware must:

```
INT  → OUTPUT LOW          (sets address to 0x5D)
RESET → LOW (hold ≥10ms)
RESET → HIGH
wait 5ms
INT  → INPUT (release)
wait ≥50ms                 (GT911 ready for I2C)
```

---

## References

### Documentation

- [Device Tree Specification](https://devicetree.org/specifications/)
- [Linux V4L2 Documentation](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/v4l2.html)
- [Qualcomm CAMSS Driver](https://github.com/torvalds/linux/tree/master/drivers/media/platform/qcom/camss)
- [IMX219 Driver](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/imx219.c)

### Clock Definitions

- [QCM2290 GCC Clock IDs](https://github.com/torvalds/linux/blob/master/include/dt-bindings/clock/qcom,gcc-qcm2290.h)

### Hardware

- Arduino UNO Q Schematic: ABX00162-schematics.pdf
- RPi Camera v2 Schematic: RP-008150-DS-1-camera-module-2-schematics.pdf
- GosHawk Hat Shield Schematic

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Feb 2026 | Initial Camera 1 integration |
| 1.1 | Feb 2026 | Added Camera 2 device tree configuration |
| 1.2 | Feb 2026 | Added DSI display documentation and RPi compatibility matrix |
| 1.3 | Feb 2026 | Added audio integration guide (mic + headphone) |
| 1.4 | Feb 2026 | Comprehensive audio configuration (ALSA mixer setup, recording, diagnostics) |
| 2.0 | Mar 2026 | Freenove 4.3" display verified working (tc358762 + panel_dpi); CAMSS optional-sensor patch; camera-setup.sh auto-detection script; updated build scripts |
| 2.1 | Mar 2026 | Audio fix: disabled HDMI DAI link in Freenove DTS; rewrote configure-audio.sh with correct PM4125 controls (RX_RX0/RX1 Digital, TX_DEC0); volume/mic-gain subcommands |
| 2.2 | Mar 2026 | Corrected CSI/DSI pin info: CSI pin 12 = LED_EN (not RESET); IMX219 XCLR tied HIGH on camera PCB; added Zephyr GPIO mappings; systemd boot service (zephyria-setup.sh) |
| 2.3 | Mar 2026 | GT911 touchscreen: patched goodix_ts with polling mode (stock requires IRQ); CCI bus 0 timeout diagnosis; I2C address latching; MCU reset sequence documented |
