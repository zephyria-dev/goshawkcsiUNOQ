# Audio Integration Guide for Zephyria Shield

## Overview

The Arduino UNO Q uses the **PM4125 PMIC integrated audio codec** for analog audio I/O. The Zephyria Shield routes these signals from the JMISC connector to standard audio connectors.

**Good news:** Audio is already configured in the base Arduino DTB. The shield only needs to route the physical signals correctly.

---

## Audio Hardware Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    QRB2210 Audio Subsystem                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│   ┌─────────────────┐                                          │
│   │  ADSP (Audio    │ ← Firmware (adsp.mbn)                    │
│   │  DSP Processor) │                                          │
│   └────────┬────────┘                                          │
│            │                                                    │
│            ▼                                                    │
│   ┌─────────────────┐      ┌───────────────┐                   │
│   │  LPASS (Low     │      │  SoundWire    │                   │
│   │  Power Audio    │◄────►│  Controllers  │                   │
│   │  SubSystem)     │      │  (swr0, swr1) │                   │
│   └────────┬────────┘      └───────────────┘                   │
│            │                       │                            │
│            ▼                       ▼                            │
│   ┌─────────────────────────────────────────┐                  │
│   │           PM4125 PMIC Codec             │                  │
│   │  ┌─────────────┐   ┌─────────────┐     │                  │
│   │  │ TX (Record) │   │ RX (Play)   │     │                  │
│   │  │ - AMIC1     │   │ - HPH_L     │     │                  │
│   │  │ - AMIC2  ◄──┼───┼── HPH_R     │     │                  │
│   │  │ - AMIC3     │   │ - LO (Line) │     │                  │
│   │  │ - DMIC      │   └─────────────┘     │                  │
│   │  └─────────────┘                       │                  │
│   └─────────────────────────────────────────┘                  │
│            │                       │                            │
└────────────┼───────────────────────┼────────────────────────────┘
             │                       │
             ▼                       ▼
      ┌──────────────┐        ┌──────────────┐
      │   JMISC      │        │   JMISC      │
      │ (MIC pins)   │        │ (HPH pins)   │
      └──────┬───────┘        └──────┬───────┘
             │                       │
             ▼                       ▼
      ┌──────────────┐        ┌──────────────┐
      │  Zephyria    │        │  Zephyria    │
      │  Shield MIC  │        │  Shield HPH  │
      │  Connector   │        │  Connector   │
      └──────────────┘        └──────────────┘
```

---

## Shield Pin Mapping

### Microphone Connector

| MIC Pin | Signal | JMISC Pin | PM4125 Function | Description |
|---------|--------|-----------|-----------------|-------------|
| 1 | MIC2_INM | 31 | AMIC2 Negative | Differential mic input (-) |
| 2 | MIC2_INP | 29 (RC filter) | AMIC2 Positive | Differential mic input (+) |
| 3 | MIC2_BIAS | 33 (RC filter) | MIC BIAS2 | Mic bias voltage (1.8V) |

### Headphone Connector

| HPH Pin | Signal | JMISC Pin | PM4125 Function | Description |
|---------|--------|-----------|-----------------|-------------|
| 1 | HPH_REF | 40 | Ground Reference | Headphone ground |
| 2 | HPH_L | 36 | HPH_L | Left channel output |
| 3 | HPH_R | 38 | HPH_R | Right channel output |

---

## Current Device Tree Configuration

### PM4125 Codec Node

Located in SPMI PMIC block:

```dts
codec {
    compatible = "qcom,pm4125-codec";

    /* Power supplies */
    vdd-io-supply = <&vreg_l3a>;       /* I/O voltage */
    vdd-cp-supply = <&vreg_l5a>;       /* Charge pump */
    vdd-pa-vpos-supply = <&vreg_l5a>;  /* Power amplifier */
    vdd-mic-bias-supply = <&vreg_l4a>; /* Mic bias source */

    /* Mic bias voltages (all 1.8V = 0x1b7740 µV) */
    qcom,micbias1-microvolt = <1800000>;
    qcom,micbias2-microvolt = <1800000>;
    qcom,micbias3-microvolt = <1800000>;

    /* SoundWire device references */
    qcom,rx-device = <&pm4125_rx>;
    qcom,tx-device = <&pm4125_tx>;

    #sound-dai-cells = <1>;
    phandle = <0x8b>;
};
```

### Sound Card Node

```dts
sound {
    compatible = "qcom,qrb2210-rb1-sndcard", "qcom,qrb4210-rb2-sndcard";
    model = "Arduino-Imola-HPH-LOUT";

    pinctrl-0 = <&lpass_rx_swr_active>;
    pinctrl-names = "default";

    /* Audio routing: Connect PM4125 outputs to inputs */
    audio-routing =
        "IN1_HPHL", "HPHL_OUT",   /* Headphone Left */
        "IN2_HPHR", "HPHR_OUT",   /* Headphone Right */
        "AMIC2", "MIC BIAS2";     /* Mic 2 with bias */

    /* Multimedia playback DAI links */
    mm1-dai-link { link-name = "MultiMedia1"; ... };
    mm2-dai-link { link-name = "MultiMedia2"; ... };
    mm3-dai-link { link-name = "MultiMedia3"; ... };
    mm4-dai-link { link-name = "MultiMedia4"; ... };

    /* Headphone playback */
    hph-playback-dai-link {
        link-name = "HPH Playback";
        cpu { sound-dai = <&q6apm 0x71>; };
        platform { sound-dai = <&q6apm>; };
        codec { sound-dai = <&pm4125_codec 0x00
                             &pm4125_rx 0x00
                             &rxmacro 0x00>; };
    };

    /* Headphone/Mic capture */
    hph-capture-dai-link {
        link-name = "HP Capture";
        cpu { sound-dai = <&q6apm 0x78>; };
        platform { sound-dai = <&q6apm>; };
        codec { sound-dai = <&pm4125_codec 0x01
                             &pm4125_tx 0x00
                             &txmacro 0x00>; };
    };

    /* HDMI audio (via ANX7625 USB-C) */
    hdmi-i2s-dai-link {
        link-name = "HDMI/I2S Playback";
        ...
    };
};
```

---

## Audio Should Already Work!

Based on the existing DTB configuration:

1. **Headphone output** is configured via `hph-playback-dai-link`
2. **Microphone input** is configured via `hph-capture-dai-link` using AMIC2
3. **Audio routing** maps AMIC2 to MIC BIAS2 (matches shield wiring)

The shield's MIC2 and HPH pins connect directly to PM4125 pins, so **no DTS changes should be required**.

---

## Testing Audio

### Check Audio Devices

```bash
# List sound cards
cat /proc/asound/cards

# List PCM devices
aplay -l
arecord -l

# Check ALSA controls
amixer -c 0 contents
```

### Test Headphone Output

```bash
# Install audio tools
sudo apt install alsa-utils sox

# Generate test tone
speaker-test -c 2 -t sine -f 440

# Play audio file
aplay -D hw:0,0 test.wav

# Or using PulseAudio/PipeWire
paplay test.wav
```

### Test Microphone Input

```bash
# Record 5 seconds of audio
arecord -d 5 -f cd -t wav recording.wav

# Record using specific device
arecord -D hw:0,0 -d 5 -f cd recording.wav

# Monitor microphone in real-time
arecord -f cd | aplay
```

### Adjust Volumes

```bash
# Open ALSA mixer
alsamixer

# Or set specific controls
amixer -c 0 set 'Headphone' 80%
amixer -c 0 set 'Mic' 80%

# Enable mic bias (may be needed)
amixer -c 0 set 'MIC BIAS2' on
```

---

## Troubleshooting

### No Sound Devices Found

1. **Check ADSP firmware**:
   ```bash
   ls -la /lib/firmware/qcom/qrb2210/adsp*
   dmesg | grep -i adsp
   ```

2. **Check audio modules loaded**:
   ```bash
   lsmod | grep -i snd
   lsmod | grep -i soundwire
   ```

3. **Check remoteproc status**:
   ```bash
   cat /sys/class/remoteproc/remoteproc*/state
   cat /sys/class/remoteproc/remoteproc*/name
   ```

### No Sound from Headphones

1. **Check routing**:
   ```bash
   amixer -c 0 | grep -A2 "HPH\|Headphone"
   ```

2. **Check if muted**:
   ```bash
   amixer -c 0 set 'Headphone' unmute
   ```

3. **Check physical connection** - verify shield connector is properly seated

### Microphone Not Working

1. **Enable mic bias**:
   ```bash
   amixer -c 0 set 'MIC BIAS2' on
   ```

2. **Check capture controls**:
   ```bash
   amixer -c 0 | grep -A2 "Mic\|AMIC"
   ```

3. **Verify wiring** - check shield MIC connector to JMISC

### ADSP Not Loading

Check for missing firmware:
```bash
# Required firmware files
ls -la /lib/firmware/qcom/qrb2210/
# Should include: adsp.mbn, adsp*.mdt
```

---

## Modifying Audio Configuration (If Needed)

### Change Mic Bias Voltage

If your microphone requires different bias voltage (e.g., 2.7V for some electret mics):

```dts
codec {
    compatible = "qcom,pm4125-codec";
    /* ... other properties ... */

    /* Change mic bias from 1.8V to 2.7V */
    qcom,micbias2-microvolt = <2700000>;
};
```

### Use Different Microphone Input

If using AMIC1 or AMIC3 instead of AMIC2:

```dts
sound {
    /* ... */

    /* Change from AMIC2 to AMIC1 */
    audio-routing =
        "IN1_HPHL", "HPHL_OUT",
        "IN2_HPHR", "HPHR_OUT",
        "AMIC1", "MIC BIAS1";  /* Changed from AMIC2, MIC BIAS2 */
};
```

### Add Line Output

If shield has line output in addition to headphones:

```dts
sound {
    audio-routing =
        "IN1_HPHL", "HPHL_OUT",
        "IN2_HPHR", "HPHR_OUT",
        "AMIC2", "MIC BIAS2",
        "IN3_LO", "LO_OUT";  /* Add line output */
};
```

---

## Audio Routing Reference

### PM4125 Output Pins (RX/Playback)

| Output | Signal | Description |
|--------|--------|-------------|
| HPHL_OUT | HPH_L | Headphone Left |
| HPHR_OUT | HPH_R | Headphone Right |
| LO_OUT | LO | Line Out |
| EAR_OUT | EAR | Earpiece (not used on shield) |

### PM4125 Input Pins (TX/Capture)

| Input | Signal | Description |
|-------|--------|-------------|
| AMIC1 | MIC1 | Analog Mic 1 (with BIAS1) |
| AMIC2 | MIC2 | Analog Mic 2 (with BIAS2) - **Shield uses this** |
| AMIC3 | MIC3 | Analog Mic 3 (with BIAS3) |
| DMIC | DMIC | Digital Mic (I2S interface) |

---

## Required Kernel Modules

These should already be built into the Arduino kernel:

| Module | Purpose |
|--------|---------|
| `snd_soc_qcom_common` | Qualcomm sound core |
| `snd_soc_sm8250` | SM8250/QCM2290 audio |
| `snd_soc_qcom_sdw` | SoundWire support |
| `snd_soc_wcd_mbhc` | Headset detection |
| `snd_soc_wcd_swr` | WCD SoundWire |

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | Feb 2026 | Initial audio integration guide |
