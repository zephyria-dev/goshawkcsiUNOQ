# DSI Display Integration Guide for Zephyria Shield

## Overview

The UNO Q supports DSI (Display Serial Interface) displays via the JMEDIA connector. This guide explains how to add DSI display support to your working camera configuration.

---

## Display Subsystem Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    QRB2210 Display Pipeline                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   Framebuffer (/dev/fb0 or DRM)                                │
│           │                                                     │
│           ▼                                                     │
│   ┌───────────────┐                                            │
│   │     DPU       │  Display Processing Unit                   │
│   │  @0x5e01000   │  (QCM2290-DPU)                            │
│   └───────┬───────┘                                            │
│           │                                                     │
│           ▼                                                     │
│   ┌───────────────┐                                            │
│   │     DSI       │  DSI Controller                            │
│   │  @0x5e94000   │  (QCM2290-DSI-CTRL)                       │
│   └───────┬───────┘                                            │
│           │                                                     │
│           ▼                                                     │
│   ┌───────────────┐                                            │
│   │   DSI PHY     │  Physical Layer                            │
│   │  @0x5e94400   │  (DSI-PHY-14NM-2290)                      │
│   └───────┬───────┘                                            │
│           │                                                     │
│           ▼                                                     │
│       MIPI DSI                                                  │
│     (2 or 4 lanes)                                             │
│           │                                                     │
│           ▼                                                     │
│   ┌───────────────┐                                            │
│   │    Panel      │  Display Panel (ST7701, ILI9881C, etc.)   │
│   └───────────────┘                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Components

### 1. Display Subsystem (MDSS)
- **Address**: `0x5e00000`
- **Compatible**: `qcom,qcm2290-mdss`
- **Purpose**: Top-level display subsystem controller

### 2. Display Processing Unit (DPU)
- **Address**: `0x5e01000`
- **Compatible**: `qcom,qcm2290-dpu`
- **Purpose**: Framebuffer processing, scaling, color conversion

### 3. DSI Controller
- **Address**: `0x5e94000`
- **Compatible**: `qcom,qcm2290-dsi-ctrl`
- **Purpose**: MIPI DSI protocol handling

### 4. DSI PHY
- **Address**: `0x5e94400`
- **Compatible**: `qcom,dsi-phy-14nm-2290`
- **Purpose**: Physical layer, clock generation

### 5. Display Clock Controller
- **Address**: `0x5f00000`
- **Compatible**: `qcom,qcm2290-dispcc`
- **Purpose**: Display-specific clocks

---

## Device Tree Configuration

### Step 1: Add Panel Power Regulator

```dts
/* Add in root node, near camera regulators */
panel-pwr {
    compatible = "regulator-fixed";
    regulator-name = "panel-pwr";
    phandle = <0x1f0>;
    regulator-always-on;
    regulator-boot-on;
    /* If GPIO-controlled power, add:
    gpio = <&tlmm XX 0>;
    enable-active-high;
    startup-delay-us = <10000>;
    */
};
```

### Step 2: Enable Display Subsystem (MDSS)

Find and modify the `display-subsystem@5e00000` node:

```dts
display-subsystem@5e00000 {
    compatible = "qcom,qcm2290-mdss";
    reg = <0x00 0x5e00000 0x00 0x1000>;
    /* ... existing properties ... */
    status = "okay";  /* <-- Enable this */

    /* display-controller and dsi nodes inside */
};
```

### Step 3: Enable DPU (Display Controller)

Inside `display-subsystem@5e00000`:

```dts
display-controller@5e01000 {
    compatible = "qcom,qcm2290-dpu";
    /* ... existing properties ... */
    status = "okay";  /* Already okay in base */

    ports {
        port@0 {
            reg = <0>;
            dpu_intf1_out: endpoint {
                remote-endpoint = <&dsi0_in>;  /* Link to DSI */
            };
        };
    };
};
```

### Step 4: Configure DSI Controller

Inside `display-subsystem@5e00000`:

```dts
dsi@5e94000 {
    compatible = "qcom,qcm2290-dsi-ctrl", "qcom,mdss-dsi-ctrl";
    reg = <0x00 0x5e94000 0x00 0x400>;
    /* ... clocks, power-domains ... */

    status = "okay";
    vdda-supply = <&vreg_l5a>;  /* 1.2V DSI PLL supply */

    #address-cells = <1>;
    #size-cells = <0>;

    /* Panel node - CUSTOMIZE FOR YOUR DISPLAY */
    panel@0 {
        compatible = "your-vendor,your-panel";  /* <-- CHANGE THIS */
        reg = <0>;
        status = "okay";

        /* Panel configuration */
        dsi-lanes = <2>;           /* Number of DSI lanes (2 or 4) */
        video-mode = <2>;          /* 0=command, 1=video-sync-pulse, 2=video-sync-event, 3=video-burst */

        /* Power supplies */
        VCC-supply = <&panel_pwr>;
        IOVCC-supply = <&panel_pwr>;

        /* Reset GPIO - ADJUST for your shield */
        reset-gpios = <&tlmm 2 0>;  /* GPIO2, active-low */

        /* Optional: backlight */
        /* backlight = <&backlight>; */

        port {
            panel_in: endpoint {
                remote-endpoint = <&dsi0_out>;
            };
        };
    };

    ports {
        #address-cells = <1>;
        #size-cells = <0>;

        port@0 {
            reg = <0>;
            dsi0_in: endpoint {
                remote-endpoint = <&dpu_intf1_out>;
            };
        };

        port@1 {
            reg = <1>;
            dsi0_out: endpoint {
                remote-endpoint = <&panel_in>;
                data-lanes = <0 1>;  /* Lane mapping */
            };
        };
    };
};
```

### Step 5: Enable DSI PHY

Inside `display-subsystem@5e00000`:

```dts
phy@5e94400 {
    compatible = "qcom,dsi-phy-14nm-2290";
    /* ... existing properties ... */
    status = "okay";
};
```

---

## Common Panel Drivers

### Panels with Mainline Linux Support

| Panel IC | Compatible String | Lanes | Notes |
|----------|-------------------|-------|-------|
| ST7701 | `sitronix,st7701` | 2 | Arduino GigaDisplay uses this |
| ILI9881C | `ilitek,ili9881c` | 4 | Common in tablets |
| NT35596 | `novatek,nt35596` | 4 | High-res phones |
| HX8394 | `himax,hx8394` | 4 | Budget displays |
| OTM8009A | `orisetech,otm8009a` | 2 | Common eval boards |

### Arduino GigaDisplay Configuration

From Arduino's `qrb2210-arduino-imola-gigadisplay.dtb`:

```dts
panel@0 {
    compatible = "arduino,giga-display", "sitronix,st7701";
    reg = <0>;
    status = "okay";

    video-mode = <2>;           /* Video sync-event mode */
    dsi-lanes = <2>;            /* 2-lane DSI */

    reset-gpios = <&tlmm 2 0>;  /* GPIO2 for reset */

    IOVCC-supply = <&panel_pwr>;
    VCC-supply = <&panel_pwr>;

    port {
        endpoint {
            remote-endpoint = <&dsi0_out>;
        };
    };
};
```

---

## Zephyria Shield DSI Connector Pinout (Confirmed)

| DSI Pin  | Signal           | JMEDIA Pin       | JMISC Pin  | Domain              |
|----------|------------------|------------------|------------|---------------------|
| 1,4,7,10 | GND              | —                | —          | —                   |
| 2        | MIPI_DSI0_L0_N   | 10               | —          | QRB2210 (Linux) ✓   |
| 3        | MIPI_DSI0_L0_P   | 12               | —          | QRB2210 (Linux) ✓   |
| 5        | MIPI_DSI0_L1_N   | 6                | —          | QRB2210 (Linux) ✓   |
| 6        | MIPI_DSI0_L1_P   | 4                | —          | QRB2210 (Linux) ✓   |
| 8        | MIPI_DSI0_CLK_N  | 3                | —          | QRB2210 (Linux) ✓   |
| 9        | MIPI_DSI0_CLK_P  | 5                | —          | QRB2210 (Linux) ✓   |
| 11       | DISP_EN          | —                | 11 (STM32 PI4, Zephyr GPIO 35) | **STM32 only** ⚠ |
| 12       | DISP_RESET       | —                | 13 (STM32 PI6, Zephyr GPIO 37) | **STM32 only** ⚠ |
| 13       | CCI_I2C_SCL0     | 51 (via PCA9306) | —          | QRB2210 (Linux) ✓   |
| 14       | CCI_I2C_SDA0     | 53 (via PCA9306) | —          | QRB2210 (Linux) ✓   |
| 15       | 3V3              | —                | —          | always-on ✓         |

### Shield Design Limitation — DISP_EN and DISP_RESET

Only **DSI pins 11 (DISP_EN)** and **12 (DISP_RESET)** are routed through JMISC to the STM32U585 MCU (Zephyr) domain. They are **not** accessible as Linux TLMM GPIOs.

All other DSI connector signals (MIPI lanes, CCI I2C, 3V3) are in the QRB2210 (Linux/MPU) domain and fully controllable from Linux.

> **Note on CSI vs DSI connectors:** The CSI camera connectors only route **one** control pin per camera (ENABLE, CSI pin 11). CSI pin 12 is **LED_EN** (camera board LED), not a reset — the IMX219 XCLR is tied HIGH on the camera module PCB. The DSI connector is different: it routes **both** DISP_EN (pin 11) and DISP_RESET (pin 12) through JMISC.

### Hardware Workarounds

**DISP_EN (DSI pin 11 → JMISC pin 11 / STM32 PI4 / Zephyr GPIO 35):**
Must be held HIGH for the display to operate:
```
Wire DSI connector pin 11 → pin 15 (3V3)
```

**DISP_RESET (DSI pin 12 → JMISC pin 13 / STM32 PI6 / Zephyr GPIO 37):**
TC358762 + GT911 reset (active-low — HIGH = operational):

| Option | Circuit | Notes |
|--------|---------|-------|
| A — RC reset | 100 nF (pin 12 → GND) + 10 kΩ (pin 12 → 3V3) | Releases reset ~1 ms after power-on |
| B — Tie high | Wire pin 12 → 3V3 | Works if 3V3 supply is clean at cold boot |
| C — STM32 FW | Zephyr sketch: `digitalWrite(37, LOW); delay(100); digitalWrite(37, HIGH);` | Cleanest — proper reset pulse. See `arduino_ide/cam_dual_io/cam_dual_io.ino` |

---

## Freenove 4.3" Display — Verified Working

The Freenove 4.3" DSI display has been fully verified on the Arduino UNO Q with Zephyria Shield. The display pipeline produces a working 800x480 framebuffer.

### Architecture

The Freenove 4.3" uses a **two-stage bridge** approach. The TC358762 is a DSI-to-DPI bridge (not a panel driver), so it requires a downstream DPI panel driver:

```
DPU → DSI Host → TC358762 (DSI-to-DPI) → panel-dpi (generic DPI) → LCD
                  ├── port@0 ← DSI input        └── panel-timing from DT
                  └── port@1 → DPI output
```

**Key discovery**: TC358762 calls `devm_drm_of_get_bridge(dev, dev->of_node, 1, 0)` — it looks for a downstream bridge/panel on `port@1`. Without this, the DSI device stays in deferred probe and `/dev/dri/` never appears.

### Required Kernel Modules

| Module | Source | Purpose |
|--------|--------|---------|
| `tc358762.ko` | `drivers/gpu/drm/bridge/tc358762.c` | DSI-to-DPI bridge |
| `panel_dpi.ko` | `scripts/src/panel_dpi.c` (custom) | Generic DPI panel reading timings from DT |

**Why `panel_dpi.ko`?** The upstream `panel-dpi.c` was removed from Linux 6.16. The stock kernel's `panel-simple` module does not include `seiko,43wvf1g` or other Freenove-compatible entries. A custom minimal DPI panel driver (~160 lines) is provided in `scripts/src/panel_dpi.c`.

### Quick Start

```bash
# Step 1 — Build required kernel modules
scripts/build-dsi-ondevice.sh tc358762
scripts/build-dsi-ondevice.sh panel_dpi
# Or build all: scripts/build-dsi-ondevice.sh all

# Step 2 — Ensure modules load at boot
echo "tc358762" | sudo tee -a /etc/modules
echo "panel_dpi" | sudo tee -a /etc/modules

# Step 3 — Apply hardware workarounds on the shield
#   • Wire DSI connector pin 11 → pin 15 (DISP_EN = 3V3)
#   • Add RC reset or tie pin 12 to 3V3 (see pinout table above)

# Step 4 — Install the Freenove DTB
#   The DTS file is a standalone DTB (not an overlay) based on
#   imola-camera-shield.dts with targeted edits.
dtc -I dts -O dtb -o imola-camera-dsi-freenove.dtb \
    dts/imola-camera-dsi-freenove.dts
sudo cp imola-camera-dsi-freenove.dtb /boot/efi/dtb/qcom/

# Step 5 — Select new DTB in boot loader
#   Edit /boot/efi/loader/entries/*.conf:
#   devicetree /dtb/qcom/imola-camera-dsi-freenove.dtb

# Step 6 — Reboot
sudo reboot
```

### Verification

After reboot, confirm the display pipeline:

```bash
# DRM devices should exist
ls /dev/dri/
# Expected: card0  renderD128

# Framebuffer should be registered
dmesg | grep fb0
# Expected: fb0: msmdrmfb frame buffer device

# Connector should be connected
cat /sys/class/drm/card0-*/status
# Expected: connected

# Check display mode
cat /sys/class/drm/card0-*/modes
# Expected: 800x480

# Test: fill screen with random pixels
cat /dev/urandom > /dev/fb0
```

### What the DTS Changes

| Change | Reason |
|--------|--------|
| Adds `panel-pwr` regulator (always-on 3V3) | Powers TC358762 bridge |
| Adds `lcd-panel` node (`compatible = "panel-dpi"`) with `panel-timing` | Generic DPI panel with 800x480 @ 33.3 MHz timings |
| Adds `panel@0` node (`toshiba,tc358762`) with `ports { port@0, port@1 }` | DSI-to-DPI bridge with downstream panel link |
| Changes `data-lanes` from `<0 1 2 3>` to `<0 1>` | Shield only routes 2 DSI lanes |
| Disables ANX7625 (`status = "disabled"`) | Prevents sysfs duplicate on DSI bus |
| Redirects `mdss_dsi0_out` remote-endpoint from ANX7625 to TC358762 | Connects pipeline |
| Adds `touchscreen@5d` (Goodix GT911) on `cci_i2c0` | I2C touch via JMEDIA/PCA9306 |

### Panel Timing (Freenove 4.3" / 800x480)

```dts
panel-timing {
    clock-frequency = <33333000>;   /* 33.3 MHz pixel clock */
    hactive = <800>;
    hfront-porch = <164>;
    hback-porch = <89>;
    hsync-len = <8>;
    vactive = <480>;
    vfront-porch = <37>;
    vback-porch = <23>;
    vsync-len = <6>;
    hsync-active = <0>;
    vsync-active = <0>;
    de-active = <1>;
    pixelclk-active = <0>;
};
```

> **Note**: The Freenove DTB redirects DSI-0 output from the ANX7625
> USB-C encoder to the TC358762 bridge. HDMI-over-USB-C is unavailable
> while this DTB is active. Boot with `imola-camera-shield.dtb` to restore
> HDMI output.

### Issues Resolved During Bring-Up

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| ANX7625 sysfs duplicate (`-EEXIST`) | ANX7625 registered DSI device at same address as panel@0 | `status = "disabled"` on ANX7625 node |
| No `/dev/dri/` despite tc358762 loaded | TC358762 requires downstream panel on `port@1` | Added `ports { port@0, port@1 }` and `lcd-panel` node |
| `seiko,43wvf1g` not in panel-simple | This kernel's panel-simple has limited entries | Switched to custom `panel-dpi` driver |
| `panel-dpi.c` not in upstream kernel | File removed from Linux 6.16 | Custom `scripts/src/panel_dpi.c` |
| `drm_panel_add()` build error | Returns void in Linux 6.16, not int | Fixed in custom panel_dpi.c |
| DSI device stuck in deferred probe | panel-simple not autoloading | Added modules to `/etc/modules` |

---

## Testing Display

### Check DRM Devices

```bash
# List DRM devices
ls -la /dev/dri/

# Show display info
cat /sys/class/drm/card*/status
cat /sys/class/drm/card*/modes

# Using modetest
modetest -M msm
```

### Check Display Pipeline

```bash
# Kernel messages
dmesg | grep -iE "dsi|dpu|mdss|panel|display"

# Check if panel driver loaded
lsmod | grep -iE "panel|st7701"

# Check DSI PHY
cat /sys/kernel/debug/dri/*/state
```

### Simple Display Test

```bash
# Fill framebuffer with color
cat /dev/urandom > /dev/fb0

# Or use fbset
fbset -i

# Test pattern
apt install fbset
fbset -test
```

### Using DRM (Recommended)

```bash
# Install tools
apt install libdrm-tests

# Run mode setting test
modetest -M msm -s <connector_id>@<crtc_id>:<mode>

# Example
modetest -M msm -s 35@31:480x800
```

---

## Troubleshooting

### No /dev/fb0 or /dev/dri

1. Check MDSS is enabled:
   ```bash
   cat /sys/devices/platform/soc@0/5e00000.display-subsystem/status
   ```

2. Check for driver errors:
   ```bash
   dmesg | grep -i "mdss\|dpu\|fail\|error"
   ```

3. Verify DSI PHY clocks:
   ```bash
   cat /sys/kernel/debug/clk/clk_summary | grep -i dsi
   ```

### Panel Not Detected

1. Check panel compatible string matches a kernel driver
2. Verify reset GPIO is correct
3. Check power supply connections
4. Look for panel probe errors:
   ```bash
   dmesg | grep -i "panel\|st7701\|probe"
   ```

### Display Garbage/Artifacts

1. Check DSI lane configuration matches panel
2. Verify video-mode setting
3. Check timing parameters if using custom panel
4. Verify voltage levels (1.8V I/O for most panels)

### Blank Screen (Backlight On)

1. Check DPU → DSI → Panel endpoint connections
2. Verify pixel format compatibility
3. Check resolution matches panel native resolution

### LPASS Pinctrl "Failed to get clk 'audio'" (Audio Not Working)

**Symptom**: `dmesg` shows:
```
platform a7c0000.pinctrl: deferred probe pending: Failed to get clk 'audio'
platform a740000.soundwire-controller: deferred probe pending
platform sound: deferred probe pending
```

**Root Cause**: The LPASS LPI pin controller (`pinctrl@a7c0000`) needs the `"audio"` clock from `q6afecc`, which is a child of the Q6 AFE APR service inside the ADSP remoteproc. The full dependency chain:

```
lpass_tlmm → q6afecc (clock) → q6afe (APR svc) → qcom_apr → ADSP remoteproc
                                                       ↑
                                                 qcom_glink_smem
```

All audio modules are built as `=m` (loadable). If they load after the kernel's `deferred_probe_timeout` (default 30s), the clock provider is never available and `lpass_tlmm` permanently fails — cascading to all SoundWire controllers and the sound card.

**Fix**:
```bash
sudo scripts/fix-audio-clock.sh
sudo reboot
```

This creates `/etc/modules-load.d/audio-clock-chain.conf` to ensure `qcom_glink_smem`, `qcom_apr`, and `snd_soc_qdsp6` load early at boot, well before the deferred probe timeout.

**Verification**:
```bash
scripts/fix-audio-clock.sh status     # Check all components
dmesg | grep -E 'a7c0000|q6afe'      # Should show successful probe
cat /proc/asound/cards                # Should list sound card
```

### No Sound Card — "HDMI/I2S Playback: codec dai not found"

**Symptom**: `dmesg` shows:
```
platform sound: deferred probe pending: snd-sm8250: HDMI/I2S Playback: codec dai not found
```
`alsamixer` reports "cannot open mixer: No such file or directory".

**Root Cause**: The `sound` node in the DTS has an `hdmi-i2s-dai-link` that references the ANX7625 audio codec. When ANX7625 is `status = "disabled"` (for DSI panel use), the codec DAI doesn't exist, and the entire sound card fails to register.

**Fix**: Add `status = "disabled"` to the `hdmi-i2s-dai-link` node in the Freenove DTS:
```dts
hdmi-i2s-dai-link {
    link-name = "HDMI/I2S Playback";
    status = "disabled";
    ...
};
```
This works because the Qualcomm sound card driver (`sound/soc/qcom/common.c`) uses `for_each_available_child_of_node()`, which skips disabled nodes.

Already applied in `dts/imola-camera-dsi-freenove.dts`. Recompile and reinstall the DTB.

### No Volume/Mic Controls in alsamixer

**Symptom**: alsamixer opens but only shows routing switches, no "Volume" or "Mic" slider.

**Root Cause**: The PM4125 codec with QDSP6 pipeline uses routing-based ALSA controls — there are no traditional simple mixer controls. Headphone volume is `RX_RX0 Digital` / `RX_RX1 Digital` (0–84). Mic gain is `TX_DEC0` (0–20).

**Fix**: Use `scripts/configure-audio.sh` which sets up all routing and provides volume/mic-gain subcommands:
```bash
scripts/configure-audio.sh              # Full setup (80% vol, 60% mic)
scripts/configure-audio.sh volume 50    # Adjust headphone 0–100%
scripts/configure-audio.sh mic-gain 80  # Adjust mic 0–100%
```
In alsamixer, press **F5** to show all controls — volume controls are under `RX_RX0 Digital`.

### GT911 Touchscreen Not Working — "I2C communication failure: -110"

**Symptom**: `dmesg` shows:
```
Goodix-TS 2-005d: Error reading 1 bytes from 0x8140: -110
Goodix-TS 2-005d: I2C communication failure: -110
Goodix-TS 2-005d: probe with driver Goodix-TS failed with error -110
```
The GT911 at address 0x5D on CCI I2C bus 0 (i2c-2) does not respond.

**Root Cause — Stock driver requires IRQ**: The upstream `goodix_ts.ko` (`CONFIG_TOUCHSCREEN_GOODIX=m`) unconditionally calls `devm_request_threaded_irq()`. Since the GT911 INT pin is routed to the STM32 domain (JMISC pin → Zephyr GPIO 35), there is no Linux GPIO for it. With `client->irq == 0`, the probe fails.

**Fix — Patched goodix_ts with polling mode**:
A patched `goodix.c` in `scripts/src/` adds `input_setup_polling()` fallback when no IRQ is available. Build and install:
```bash
# Cross-compile (or on-device):
scripts/build-dsi-modules.sh goodix_ts

# On the UNO Q — replace stock module:
KVER=$(uname -r)
sudo cp /tmp/dsi-modules-build/goodix_ts/goodix_ts.ko \
  /lib/modules/$KVER/kernel/drivers/input/touchscreen/
sudo depmod -a
sudo rmmod goodix_ts 2>/dev/null
sudo modprobe goodix_ts
```

**If still failing (-110 timeout)**: The I2C bus itself is dead. Check:
```bash
# Scan CCI bus 0 for any device
sudo i2cdetect -y 2

# Check for CCI hardware timeouts
dmesg | grep -i cci
```

If you see `master 0 queue 0 timeout` and no devices on the bus — this is a **physical connectivity issue** on CCI I2C bus 0:

| Check | Detail |
|-------|--------|
| **Camera 0 (J4)** | A faulted camera on the same I2C bus can hold SDA/SCL low. Disconnect and re-scan. |
| **DSI FPC cable** | Pins 13 (SCL) and 14 (SDA) need solid contact in the connector |
| **PCA9306 level-shifter** | Needs VREF on both sides to translate 1.8V↔3.3V |
| **CCI bus 0 shares**: | Camera 0 I2C + DSI connector I2C (gpio22/gpio23 → JMEDIA 51/53) |

**GT911 I2C address latching**: The GT911 latches its I2C address during the RESET rising edge based on the INT pin level:
- INT LOW during RESET↑ → **0x5D** (DTS default)
- INT HIGH during RESET↑ → **0x14**

The MCU firmware must drive INT LOW before releasing RESET:
```
INT  → OUTPUT LOW
RESET → LOW (hold ≥10ms)
RESET → HIGH
wait 5ms
INT  → INPUT (release)
wait ≥50ms        ← GT911 ready for I2C
```

---

## Clock IDs for Display (DISPCC)

| Clock Name | ID | Purpose |
|------------|-----|---------|
| DISP_CC_MDSS_BYTE0_CLK | 3 | DSI byte clock |
| DISP_CC_MDSS_BYTE0_INTF_CLK | 6 | DSI byte interface |
| DISP_CC_MDSS_PCLK0_CLK | 13 | Pixel clock |
| DISP_CC_MDSS_ESC0_CLK | 7 | Escape clock |
| DISP_CC_MDSS_AHB_CLK | 1 | AHB interface |
| DISP_CC_MDSS_MDP_CLK | 9 | MDP core clock |
| DISP_CC_MDSS_VSYNC_CLK | 15 | VSync clock |

---

## Kernel Module Build Reference

The following modules must be built as out-of-tree `.ko` files — none are included in the stock Arduino UNO Q kernel:

| Module | For | Build command | Status |
|--------|-----|---------------|--------|
| `tc358762.ko` | Freenove 4.3", RPi 7", WaveShare DSI | `build-dsi-ondevice.sh tc358762` | **Verified** |
| `panel_dpi.ko` | Generic DPI panel (downstream of TC358762) | `build-dsi-ondevice.sh panel_dpi` | **Verified** |
| `ili9881c.ko` | WaveShare 5"/7"/10.1" DSI | `build-dsi-ondevice.sh ili9881c` | Untested |
| `st7701.ko` | Arduino GigaDisplay, HyperPixel 4 | `build-dsi-ondevice.sh st7701` | Untested |
| `hx8394.ko` | Generic 720p budget DSI panels | `build-dsi-ondevice.sh hx8394` | Untested |
| `otm8009a.ko` | STM32 Discovery / eval boards | `build-dsi-ondevice.sh otm8009a` | Untested |
| `goodix_ts.ko` | Goodix GT911/GT9xx touch (polling mode) | `build-dsi-modules.sh goodix_ts` | **Patched** |

### Build Scripts

| Script | Use When | Notes |
|--------|----------|-------|
| `scripts/build-dsi-ondevice.sh` | On the UNO Q board | Clones kernel source if needed; installs modules automatically |
| `scripts/cross-build-dsi-modules.sh` | On a Linux host PC | Cross-compiles for arm64; copies .ko to `/tmp/dsi-modules-cross/modules/` |
| `scripts/build-camss-patched.sh` | Camera with optional sensors | Patches CAMSS to skip absent cameras (see below) |
| `scripts/camera-setup.sh` | Detect and configure cameras | Auto-detects sensors, traces pipeline, configures formats, captures |
| `scripts/fix-audio-clock.sh` | Fix LPASS audio clock failure | Ensures QDSP6 modules load before deferred probe timeout |
| `scripts/configure-audio.sh` | Configure headphone + mic | Sets PM4125 routing; volume/mic-gain/status subcommands |

### Local Source Overrides

The build scripts check `scripts/src/` for local source files before downloading from GitHub. Currently provided:

- `scripts/src/panel_dpi.c` — Custom panel-dpi driver (upstream removed in Linux 6.16)
- `scripts/src/goodix.c` — Patched Goodix touchscreen driver with `input_setup_polling()` fallback (stock driver requires IRQ which is unavailable)
- `scripts/src/goodix.h` — Goodix header (unmodified, needed for build)
- `scripts/src/goodix_fwupload.c` — Goodix firmware upload (unmodified, needed for build)

## CAMSS Optional-Sensor Patch

### Problem

The stock CAMSS kernel module uses a v4l2 async notifier that waits for **ALL** sensors declared in the device tree to bind before calling `media_device_register()`. If any camera connector is unpopulated (no physical sensor), the async notifier never completes, `/dev/media0` never appears, and the entire camera subsystem is unusable — even cameras that ARE connected cannot be used.

### Solution

The `build-camss-patched.sh` script rebuilds the `qcom-camss.ko` module with a patch that:

1. **Checks `of_device_is_available(remote)`** — skips sensors with `status = "disabled"` in DT
2. **Probes the I2C bus** — calls `i2c_smbus_xfer()` to check if the sensor responds at its address. If no device answers (NACK), the sensor is skipped with a log message

This allows CAMSS to complete initialization with only the physically present sensors.

### Build and Deploy

```bash
# On-device (requires prepared kernel source from previous build-dsi-ondevice.sh run):
scripts/build-camss-patched.sh /opt/arduino-linux-qcom

# Cross-compile:
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
  scripts/build-camss-patched.sh /tmp/dsi-modules-cross/linux-qcom
```

Deploy to the board:
```bash
KVER=$(uname -r)
DEST=/lib/modules/$KVER/kernel/drivers/media/platform/qcom/camss
sudo cp $DEST/qcom-camss.ko $DEST/qcom-camss.ko.orig   # backup
sudo cp /tmp/camss-patched/qcom-camss.ko $DEST/
sudo depmod -a && sudo reboot
```

### Verification

```bash
# Should show /dev/media0 even with only one camera connected
ls /dev/media*

# Check which sensors were detected/skipped
dmesg | grep -i 'sensor.*detected\|sensor.*skipping\|camss'

# Media pipeline should be available
media-ctl -d /dev/media0 -p
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Feb 2026 | Initial DSI display guide |
| 1.1 | Feb 2026 | Confirmed pin map; DISP_EN/DISP_RESET STM32 limitation; Freenove overlay; module build scripts |
| 2.0 | Mar 2026 | Freenove 4.3" verified working; TC358762 port@1 requirement documented; custom panel_dpi driver; CAMSS optional-sensor patch; complete bring-up issues and fixes |
| 2.1 | Mar 2026 | LPASS audio clock dependency fix (q6afecc/deferred probe); fix-audio-clock.sh script |
| 2.2 | Mar 2026 | HDMI DAI link fix for DSI panel mode; configure-audio.sh rewritten for PM4125 controls; alsamixer troubleshooting |
| 2.3 | Mar 2026 | Corrected DISP_EN/DISP_RESET with STM32 pin names and Zephyr GPIO numbers; added cam_dual_io.ino reference; GT911 reset sharing note |
| 2.4 | Mar 2026 | GT911 touchscreen investigation: stock goodix_ts requires IRQ (unavailable); patched driver with polling mode; CCI bus 0 timeout diagnosis; I2C address latching sequence documented |
