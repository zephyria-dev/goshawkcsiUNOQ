#!/bin/bash
#
# Detect, configure, and capture from IMX219 cameras on Arduino UNO Q
#
# Automatically identifies which cameras are connected, traces the media
# pipeline to find the correct /dev/videoX device for each, and configures
# the pipeline formats.
#
# Usage:
#   ./camera-setup.sh              # Detect and configure cameras
#   ./camera-setup.sh capture      # Configure + capture one frame from each
#   ./camera-setup.sh stream CAM1  # Configure + continuous stream from CAM1
#
# The script assigns stable names:
#   CAM0 = sensor on CCI I2C bus 0 (J4 connector)
#   CAM1 = sensor on CCI I2C bus 1 (J3 connector)
#

set -e

MEDIA_DEV="/dev/media0"
FORMAT="SRGGB10_1X10"
WIDTH=1920
HEIGHT=1080
PIX_FMT="pRAA"   # 10-bit packed Bayer (MIPI)
FRAME_COUNT=1
TIMEOUT=10

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ── Check prerequisites ─────────────────────────────────────────────────

[ -e "$MEDIA_DEV" ] || error "/dev/media0 not found. Is qcom-camss loaded?"
command -v media-ctl &>/dev/null || error "media-ctl not found. Install v4l-utils."
command -v v4l2-ctl &>/dev/null || error "v4l2-ctl not found. Install v4l-utils."

# ── Discover sensors ─────────────────────────────────────────────────────

# Parse media-ctl -p to find all imx219 sensor entities.
# Each sensor entity name is like "imx219 N-0010" where N is the I2C adapter.
# CCI bus 0 registers as i2c adapter 1 (or similar), CCI bus 1 as adapter 2.
# We map them to CAM0/CAM1 by sorting on adapter number.

declare -A SENSOR_ENTITY    # CAM0 => "imx219 1-0010"
declare -A SENSOR_SUBDEV    # CAM0 => "/dev/v4l-subdev12"
declare -A SENSOR_I2C_BUS   # CAM0 => "1"
declare -A CAM_CSIPHY       # CAM0 => "msm_csiphy0"
declare -A CAM_CSID         # CAM0 => "msm_csid0"
declare -A CAM_VFE          # CAM0 => "msm_vfe0_rdi0"
declare -A CAM_VIDEO        # CAM0 => "/dev/video0"
declare -a CAM_LIST         # ("CAM0" "CAM1")

MEDIA_OUTPUT="$(media-ctl -d "$MEDIA_DEV" -p)"

# Find all imx219 entities
while IFS= read -r line; do
    # Match: "- entity 131: imx219 2-0010 (1 pad, 1 link, 0 routes)"
    if [[ "$line" =~ entity\ [0-9]+:\ (imx219\ ([0-9]+)-[0-9a-f]+)\ \( ]]; then
        entity="${BASH_REMATCH[1]}"
        i2c_bus="${BASH_REMATCH[2]}"

        # Read next line for subdev path
        subdev=""
        while IFS= read -r next; do
            if [[ "$next" =~ device\ node\ name\ (/dev/v4l-subdev[0-9]+) ]]; then
                subdev="${BASH_REMATCH[1]}"
                break
            fi
        done

        # Sort sensors by I2C bus number → lower bus = CAM0
        cam_idx="${#CAM_LIST[@]}"
        cam_name="CAM${cam_idx}"
        CAM_LIST+=("$cam_name")
        SENSOR_ENTITY[$cam_name]="$entity"
        SENSOR_SUBDEV[$cam_name]="$subdev"
        SENSOR_I2C_BUS[$cam_name]="$i2c_bus"
    fi
done <<< "$MEDIA_OUTPUT"

# Sort by I2C bus number (lower = CAM0)
if [ ${#CAM_LIST[@]} -gt 1 ]; then
    # Re-sort: find which has lower I2C bus
    if [ "${SENSOR_I2C_BUS[CAM1]}" -lt "${SENSOR_I2C_BUS[CAM0]}" ]; then
        # Swap
        for key in SENSOR_ENTITY SENSOR_SUBDEV SENSOR_I2C_BUS; do
            declare -n arr="$key"
            tmp="${arr[CAM0]}"
            arr[CAM0]="${arr[CAM1]}"
            arr[CAM1]="$tmp"
        done
    fi
fi

if [ ${#CAM_LIST[@]} -eq 0 ]; then
    error "No IMX219 sensors found. Check camera connections and dmesg."
fi

# ── Trace pipeline for each sensor ───────────────────────────────────────

# For each sensor, follow the ENABLED links through the pipeline:
#   sensor → csiphy → csid → vfe_rdi → video_node
trace_pipeline() {
    local cam="$1"
    local entity="${SENSOR_ENTITY[$cam]}"

    # Find which csiphy the sensor connects to
    local csiphy=""
    csiphy=$(echo "$MEDIA_OUTPUT" | grep -B5 "\"${entity}\".*ENABLED" | \
             grep -oP 'entity \d+: \K(msm_csiphy\d+)' | head -1)
    if [ -z "$csiphy" ]; then
        warn "$cam: Cannot trace csiphy link"
        return 1
    fi
    CAM_CSIPHY[$cam]="$csiphy"

    # Find which csid the csiphy connects to (ENABLED link)
    local csid=""
    # Look for ENABLED links from csiphy SOURCE pad
    csid=$(echo "$MEDIA_OUTPUT" | \
           sed -n "/entity.*${csiphy}/,/^$/p" | \
           grep 'pad1: SOURCE' -A20 | \
           grep -oP '"(msm_csid\d+)".*\[ENABLED\]' | \
           grep -oP 'msm_csid\d+' | head -1)
    if [ -z "$csid" ]; then
        # Try to find any csid that has this csiphy as ENABLED source
        csid=$(echo "$MEDIA_OUTPUT" | \
               grep -P "\"${csiphy}\".*\[ENABLED\]" | \
               grep -oP 'msm_csid\d+' | head -1)
    fi
    if [ -z "$csid" ]; then
        warn "$cam: Cannot trace csid link from $csiphy"
        return 1
    fi
    CAM_CSID[$cam]="$csid"

    # Find which vfe_rdi the csid connects to (ENABLED link)
    local vfe=""
    vfe=$(echo "$MEDIA_OUTPUT" | \
          sed -n "/entity.*${csid} /,/^- entity/p" | \
          grep -oP '"(msm_vfe\d+_rdi\d+)".*\[ENABLED\]' | \
          grep -oP 'msm_vfe\d+_rdi\d+' | head -1)
    if [ -z "$vfe" ]; then
        warn "$cam: Cannot trace VFE link from $csid"
        return 1
    fi
    CAM_VFE[$cam]="$vfe"

    # Find the /dev/videoX node connected to this VFE
    local video=""
    # The video node entity name is like msm_vfe0_video0 for msm_vfe0_rdi0
    local video_entity="${vfe/rdi/video}"
    video=$(echo "$MEDIA_OUTPUT" | \
            sed -n "/entity.*${video_entity}/,/^$/p" | \
            grep -oP 'device node name \K/dev/video\d+')
    if [ -z "$video" ]; then
        warn "$cam: Cannot find video device for $vfe"
        return 1
    fi
    CAM_VIDEO[$cam]="$video"
}

for cam in "${CAM_LIST[@]}"; do
    trace_pipeline "$cam" || true
done

# ── Display results ──────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  Camera Detection — Arduino UNO Q / Zephyria Shield${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
echo ""

for cam in "${CAM_LIST[@]}"; do
    if [ -n "${CAM_VIDEO[$cam]}" ]; then
        echo -e "  ${GREEN}✓${NC}  ${BOLD}${cam}${NC}"
    else
        echo -e "  ${YELLOW}?${NC}  ${BOLD}${cam}${NC}  (pipeline not fully traced)"
    fi
    echo "      Sensor:   ${SENSOR_ENTITY[$cam]}"
    echo "      Subdev:   ${SENSOR_SUBDEV[$cam]}"
    echo "      I2C bus:  ${SENSOR_I2C_BUS[$cam]}"
    if [ -n "${CAM_CSIPHY[$cam]}" ]; then
        echo "      Pipeline: ${CAM_CSIPHY[$cam]} → ${CAM_CSID[$cam]} → ${CAM_VFE[$cam]}"
        echo "      Video:    ${CAM_VIDEO[$cam]}"
    fi
    echo ""
done

# ── Configure pipeline ───────────────────────────────────────────────────

configure_camera() {
    local cam="$1"
    local entity="${SENSOR_ENTITY[$cam]}"
    local csiphy="${CAM_CSIPHY[$cam]}"
    local csid="${CAM_CSID[$cam]}"
    local vfe="${CAM_VFE[$cam]}"
    local fmt="${FORMAT}/${WIDTH}x${HEIGHT}"

    if [ -z "$vfe" ]; then
        warn "Skipping $cam — pipeline not traced"
        return 1
    fi

    info "Configuring $cam pipeline: $entity → $csiphy → $csid → $vfe"

    media-ctl -d "$MEDIA_DEV" --set-v4l2 "\"${entity}\":0[fmt:${fmt}]"
    media-ctl -d "$MEDIA_DEV" --set-v4l2 "\"${csiphy}\":0[fmt:${fmt}]"
    media-ctl -d "$MEDIA_DEV" --set-v4l2 "\"${csiphy}\":1[fmt:${fmt}]"
    media-ctl -d "$MEDIA_DEV" --set-v4l2 "\"${csid}\":0[fmt:${fmt}]"
    media-ctl -d "$MEDIA_DEV" --set-v4l2 "\"${csid}\":1[fmt:${fmt}]"
    media-ctl -d "$MEDIA_DEV" --set-v4l2 "\"${vfe}\":0[fmt:${fmt}]"
    media-ctl -d "$MEDIA_DEV" --set-v4l2 "\"${vfe}\":1[fmt:${fmt}]"

    info "$cam pipeline configured"
}

echo -e "${BOLD}Configuring pipelines...${NC}"
echo ""

for cam in "${CAM_LIST[@]}"; do
    configure_camera "$cam" || true
done

# ── Set default exposure ─────────────────────────────────────────────────

for cam in "${CAM_LIST[@]}"; do
    subdev="${SENSOR_SUBDEV[$cam]}"
    if [ -n "$subdev" ]; then
        v4l2-ctl -d "$subdev" --set-ctrl=exposure=5000 2>/dev/null || true
        v4l2-ctl -d "$subdev" --set-ctrl=analogue_gain=400 2>/dev/null || true
    fi
done

# ── Action: capture or stream ────────────────────────────────────────────

ACTION="${1:-}"

if [ "$ACTION" = "capture" ]; then
    echo ""
    echo -e "${BOLD}Capturing frames...${NC}"
    echo ""

    for cam in "${CAM_LIST[@]}"; do
        video="${CAM_VIDEO[$cam]}"
        [ -z "$video" ] && continue

        outfile="${cam,,}_$(date +%Y%m%d_%H%M%S).raw"
        info "$cam: Capturing from $video → $outfile"

        timeout "$TIMEOUT" v4l2-ctl -d "$video" \
            --set-fmt-video=width=${WIDTH},height=${HEIGHT},pixelformat=${PIX_FMT} \
            --stream-mmap --stream-count=${FRAME_COUNT} \
            --stream-to="$outfile" 2>&1 || {
            warn "$cam: Capture failed or timed out"
            continue
        }

        if [ -f "$outfile" ] && [ -s "$outfile" ]; then
            size=$(du -sh "$outfile" | cut -f1)
            echo -e "  ${GREEN}✓${NC}  $outfile ($size)"
        else
            echo -e "  ${RED}✗${NC}  $outfile (empty or missing)"
        fi
    done

elif [ "$ACTION" = "stream" ]; then
    TARGET_CAM="${2:-CAM0}"
    video="${CAM_VIDEO[$TARGET_CAM]}"
    [ -z "$video" ] && error "$TARGET_CAM not found or pipeline not traced"

    info "Streaming from $TARGET_CAM ($video)... Press Ctrl+C to stop."
    v4l2-ctl -d "$video" \
        --set-fmt-video=width=${WIDTH},height=${HEIGHT},pixelformat=${PIX_FMT} \
        --stream-mmap --stream-count=0
fi

# ── Summary ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Quick reference:${NC}"
echo ""
for cam in "${CAM_LIST[@]}"; do
    video="${CAM_VIDEO[$cam]}"
    subdev="${SENSOR_SUBDEV[$cam]}"
    [ -z "$video" ] && continue
    echo "  $cam: capture device = $video"
    echo "        sensor subdev = $subdev"
done
echo ""
echo "  Capture one frame:"
for cam in "${CAM_LIST[@]}"; do
    video="${CAM_VIDEO[$cam]}"
    [ -z "$video" ] && continue
    echo "    v4l2-ctl -d $video --set-fmt-video=width=${WIDTH},height=${HEIGHT},pixelformat=${PIX_FMT} \\"
    echo "        --stream-mmap --stream-count=1 --stream-to=${cam,,}.raw"
done
echo ""
echo "  Adjust exposure/gain:"
for cam in "${CAM_LIST[@]}"; do
    subdev="${SENSOR_SUBDEV[$cam]}"
    [ -z "$subdev" ] && continue
    echo "    v4l2-ctl -d $subdev --set-ctrl=exposure=5000"
    echo "    v4l2-ctl -d $subdev --set-ctrl=analogue_gain=400"
done
echo ""
