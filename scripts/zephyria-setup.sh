#!/bin/bash
#
# Zephyria Shield — Boot-time device setup
#
# Configures all shield peripherals so the board is ready to use:
#   - Audio: headphone output + microphone capture routing
#   - Camera: detect sensors, configure media pipelines
#   - Display: verify DSI panel status
#
# Called by zephyria-setup.service at boot. Can also be run manually.
#
# Usage:
#   sudo zephyria-setup.sh           # Configure everything
#   sudo zephyria-setup.sh status    # Show device status summary
#

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_TAG="zephyria-setup"
LOGFILE="/var/log/zephyria-setup.log"

# ── Logging ─────────────────────────────────────────────────────────────

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg" >> "$LOGFILE"
    logger -t "$LOG_TAG" -- "$*"
    echo "$msg"
}

log_ok()   { log "OK:   $*"; }
log_warn() { log "WARN: $*"; }
log_fail() { log "FAIL: $*"; }

# ── Audio ───────────────────────────────────────────────────────────────

setup_audio() {
    log "--- Audio setup ---"

    # Sound card depends on ADSP remoteproc → APR → codec chain (~12-15s after boot)
    local retries=0
    while ! grep -q 'card 0' /proc/asound/cards 2>/dev/null; do
        retries=$((retries + 1))
        if [ $retries -gt 6 ]; then
            log_fail "No sound card detected (waited 30s)"
            return 1
        fi
        log "Waiting for sound card... (${retries}/6)"
        sleep 5
    done

    local card_name
    card_name=$(cat /proc/asound/cards 2>/dev/null | head -1)
    log "Sound card: $card_name"

    # Headphone playback routing
    amixer -c 0 cset name='RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 1 >/dev/null 2>&1
    amixer -c 0 cset name='RX_MACRO RX0 MUX' 'AIF1_PB' >/dev/null 2>&1
    amixer -c 0 cset name='RX_MACRO RX1 MUX' 'AIF1_PB' >/dev/null 2>&1
    amixer -c 0 cset name='RX INT0_1 MIX1 INP0' 'RX0' >/dev/null 2>&1
    amixer -c 0 cset name='RX INT1_1 MIX1 INP0' 'RX1' >/dev/null 2>&1
    amixer -c 0 cset name='RX INT0 DEM MUX' 'CLSH_DSM_OUT' >/dev/null 2>&1
    amixer -c 0 cset name='RX INT1 DEM MUX' 'CLSH_DSM_OUT' >/dev/null 2>&1
    amixer -c 0 cset name='HPHL_RDAC Switch' 1 >/dev/null 2>&1
    amixer -c 0 cset name='HPHR_RDAC Switch' 1 >/dev/null 2>&1
    amixer -c 0 cset name='HPHL Switch' 1 >/dev/null 2>&1
    amixer -c 0 cset name='HPHR Switch' 1 >/dev/null 2>&1

    # Volume: 80% (67/84)
    amixer -c 0 cset name='RX_RX0 Digital' 67 >/dev/null 2>&1
    amixer -c 0 cset name='RX_RX1 Digital' 67 >/dev/null 2>&1

    log_ok "Headphone output configured (80%)"

    # Microphone capture routing
    amixer -c 0 cset name='MultiMedia1 Mixer TX_CODEC_DMA_TX_3' 1 >/dev/null 2>&1
    amixer -c 0 cset name='TX DEC0 MUX' 'SWR_MIC' >/dev/null 2>&1
    amixer -c 0 cset name='TX SMIC MUX0' 'ADC2' >/dev/null 2>&1
    amixer -c 0 cset name='ADC2 MUX' 'INP3' >/dev/null 2>&1
    amixer -c 0 cset name='TX_AIF1_CAP Mixer DEC0' 1 >/dev/null 2>&1

    # Mic gain: 60% (12/20)
    amixer -c 0 cset name='TX_DEC0' 12 >/dev/null 2>&1

    log_ok "Microphone capture configured (60%)"
}

# ── Camera ──────────────────────────────────────────────────────────────

setup_camera() {
    log "--- Camera setup ---"

    if [ ! -e /dev/media0 ]; then
        log_warn "No /dev/media0 — CAMSS not available (is qcom-camss loaded?)"
        return 1
    fi

    if ! command -v media-ctl &>/dev/null; then
        log_warn "media-ctl not found — skipping pipeline configuration"
        return 1
    fi

    local MEDIA_OUTPUT
    MEDIA_OUTPUT="$(media-ctl -d /dev/media0 -p 2>/dev/null)"

    local FORMAT="SRGGB10_1X10"
    local WIDTH=1920
    local HEIGHT=1080
    local FMT="${FORMAT}/${WIDTH}x${HEIGHT}"

    # Find all imx219 sensors
    local sensor_count=0
    while IFS= read -r line; do
        if [[ "$line" =~ entity\ [0-9]+:\ (imx219\ [0-9]+-[0-9a-f]+)\ \( ]]; then
            local entity="${BASH_REMATCH[1]}"
            sensor_count=$((sensor_count + 1))
            log "Sensor found: $entity"

            # Configure sensor format
            media-ctl -d /dev/media0 --set-v4l2 "\"${entity}\":0[fmt:${FMT}]" 2>/dev/null && \
                log_ok "Configured $entity" || \
                log_warn "Failed to configure $entity"
        fi
    done <<< "$MEDIA_OUTPUT"

    if [ $sensor_count -eq 0 ]; then
        log_warn "No IMX219 sensors detected"
        return 1
    fi

    # Configure pipeline elements (csiphy, csid, vfe)
    for element_type in msm_csiphy msm_csid msm_vfe; do
        while IFS= read -r line; do
            if [[ "$line" =~ entity\ [0-9]+:\ (${element_type}[0-9a-z_]+)\ \( ]]; then
                local elem="${BASH_REMATCH[1]}"
                # Find pad count from the entity line
                local pads
                pads=$(echo "$line" | grep -oP '\d+ pads' | grep -oP '\d+')
                if [ -n "$pads" ]; then
                    for ((p=0; p<pads; p++)); do
                        media-ctl -d /dev/media0 --set-v4l2 "\"${elem}\":${p}[fmt:${FMT}]" 2>/dev/null || true
                    done
                fi
            fi
        done <<< "$MEDIA_OUTPUT"
    done

    log_ok "$sensor_count camera(s) configured at ${WIDTH}x${HEIGHT}"

    # Set default exposure/gain on sensor subdevs
    for subdev in /dev/v4l-subdev*; do
        if v4l2-ctl -d "$subdev" --list-ctrls 2>/dev/null | grep -q exposure; then
            v4l2-ctl -d "$subdev" --set-ctrl=exposure=5000 2>/dev/null || true
            v4l2-ctl -d "$subdev" --set-ctrl=analogue_gain=400 2>/dev/null || true
        fi
    done

    log_ok "Default exposure/gain set on sensor subdevs"
}

# ── Display ─────────────────────────────────────────────────────────────

setup_display() {
    log "--- Display setup ---"

    if [ ! -d /dev/dri ]; then
        log_fail "No /dev/dri — display subsystem not available"
        return 1
    fi

    local connected=0
    for conn in /sys/class/drm/card0-*/status; do
        local name="${conn%/status}"
        name="${name##*/}"
        local status
        status=$(cat "$conn" 2>/dev/null)
        if [ "$status" = "connected" ]; then
            local mode
            mode=$(cat "${conn%/status}/modes" 2>/dev/null | head -1)
            log_ok "Display $name: connected ($mode)"
            connected=1
        fi
    done

    if [ $connected -eq 0 ]; then
        log_warn "No connected display detected"
    fi

    # Check framebuffer
    if [ -e /dev/fb0 ]; then
        log_ok "/dev/fb0 available"
    fi
}

# ── Touchscreen ─────────────────────────────────────────────────────────

check_touch() {
    log "--- Touchscreen check ---"

    local found=0
    for input in /sys/class/input/input*/name; do
        local name
        name=$(cat "$input" 2>/dev/null)
        if [[ "$name" == *oodix* ]] || [[ "$name" == *GT911* ]] || [[ "$name" == *gt9* ]]; then
            log_ok "Touchscreen: $name"
            found=1
        fi
    done

    if [ $found -eq 0 ]; then
        # Check I2C for GT911 at 0x5D or 0x14
        if command -v i2cdetect &>/dev/null; then
            for bus in /dev/i2c-*; do
                local busnum="${bus##*-}"
                if i2cdetect -y "$busnum" 2>/dev/null | grep -qE '\b(5d|14)\b'; then
                    log_warn "GT911 may be present on i2c-${busnum} but driver not bound"
                    found=2
                fi
            done
        fi
        if [ $found -eq 0 ]; then
            log_warn "Touchscreen not detected (GT911 not found on I2C)"
        fi
    fi
}

# ── Status ──────────────────────────────────────────────────────────────

show_status() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  Zephyria Shield — Device Status"
    echo "════════════════════════════════════════════════════════════"
    echo ""

    # Display
    echo "  Display:"
    if [ -d /dev/dri ]; then
        for conn in /sys/class/drm/card0-*/status; do
            local name="${conn%/status}"; name="${name##*/}"
            local st=$(cat "$conn" 2>/dev/null)
            local mode=$(cat "${conn%/status}/modes" 2>/dev/null | head -1)
            [ "$st" = "connected" ] && echo "    OK  $name ($mode)" || echo "    --  $name ($st)"
        done
    else
        echo "    FAIL  No /dev/dri"
    fi

    # Touchscreen
    echo ""
    echo "  Touchscreen:"
    local touch_found=0
    for input in /sys/class/input/input*/name; do
        local n=$(cat "$input" 2>/dev/null)
        if [[ "$n" == *oodix* ]] || [[ "$n" == *GT911* ]] || [[ "$n" == *gt9* ]]; then
            local dev_path="${input%/name}"
            local evdev=$(ls "$dev_path"/event* 2>/dev/null | head -1)
            evdev="${evdev##*/}"
            echo "    OK  $n (/dev/input/$evdev)"
            touch_found=1
        fi
    done
    [ $touch_found -eq 0 ] && echo "    --  Not detected"

    # Audio
    echo ""
    echo "  Audio:"
    if grep -q 'card 0' /proc/asound/cards 2>/dev/null; then
        local hphl=$(amixer -c 0 cget name='HPHL Switch' 2>/dev/null | grep 'values=' | sed 's/.*values=//')
        local rx0=$(amixer -c 0 cget name='RX_RX0 Digital' 2>/dev/null | grep 'values=' | sed 's/.*values=//')
        if [ "$hphl" = "1" ]; then
            echo "    OK  Headphone configured (volume: ${rx0}/84)"
        else
            echo "    --  Sound card present but routing not set (run: configure-audio.sh)"
        fi
        local tx=$(amixer -c 0 cget name='MultiMedia1 Mixer TX_CODEC_DMA_TX_3' 2>/dev/null | grep 'values=' | sed 's/.*values=//')
        local dec0=$(amixer -c 0 cget name='TX_DEC0' 2>/dev/null | grep 'values=' | sed 's/.*values=//')
        if [ "$tx" = "1" ]; then
            echo "    OK  Microphone configured (gain: ${dec0}/20)"
        else
            echo "    --  Mic capture not routed"
        fi
    else
        echo "    FAIL  No sound card"
    fi

    # Camera
    echo ""
    echo "  Camera:"
    if [ -e /dev/media0 ] && command -v media-ctl &>/dev/null; then
        local sensors
        sensors=$(media-ctl -d /dev/media0 -p 2>/dev/null | grep -oP 'imx219 \d+-[0-9a-f]+' | sort -u)
        if [ -n "$sensors" ]; then
            while read -r s; do
                echo "    OK  $s"
            done <<< "$sensors"
        else
            echo "    --  No sensors detected"
        fi
        # List video devices
        if command -v v4l2-ctl &>/dev/null; then
            local videos
            videos=$(v4l2-ctl --list-devices 2>/dev/null | grep '/dev/video' | tr -d '\t ')
            if [ -n "$videos" ]; then
                echo "    Video devices: $(echo $videos | tr '\n' ' ')"
            fi
        fi
    else
        echo "    FAIL  No /dev/media0"
    fi

    echo ""
    echo "  Log: $LOGFILE"
    echo ""
}

# ── Main ────────────────────────────────────────────────────────────────

ACTION="${1:-setup}"

case "$ACTION" in
    setup)
        echo "" >> "$LOGFILE"
        log "=== Zephyria Shield setup starting ==="

        # Wait briefly for devices to settle (important at boot)
        if [ "$(cat /proc/uptime | cut -d. -f1)" -lt 20 ]; then
            log "Early boot — waiting 5s for devices to settle..."
            sleep 5
        fi

        setup_display
        setup_audio
        setup_camera

        # Ensure goodix_ts (polling-mode patched) is loaded for GT911 touch
        if ! lsmod | grep -q goodix_ts 2>/dev/null; then
            modprobe goodix_ts 2>/dev/null || true
        fi

        check_touch

        log "=== Setup complete ==="
        show_status
        ;;

    status)
        show_status
        ;;

    *)
        echo "Usage: $0 [setup|status]"
        exit 1
        ;;
esac
