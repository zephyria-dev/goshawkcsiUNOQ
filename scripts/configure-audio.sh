#!/bin/bash
#
# Configure Audio on Arduino UNO Q — Zephyria Shield
#
# The Qualcomm QDSP6 audio pipeline has no traditional "Volume" or "Mic"
# mixer controls. Instead, hundreds of routing switches connect the DSP
# streams (MultiMedia1–8) through LPASS macros (RX/TX) → SoundWire →
# PM4125 codec → headphone/mic hardware.
#
# This script sets up the full routing chain and provides volume/gain
# control via the digital gain registers.
#
# Usage:
#   ./configure-audio.sh                  # Configure routing + 80% volume
#   ./configure-audio.sh volume 50        # Set headphone volume (0–100%)
#   ./configure-audio.sh mic-gain 60      # Set microphone gain (0–100%)
#   ./configure-audio.sh status           # Show current configuration
#   ./configure-audio.sh test             # Quick playback test
#

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BLUE}${BOLD}=== $1 ===${NC}\n"; }

CARD=0

# ── Helper ──────────────────────────────────────────────────────────────

set_ctl() {
    local name="$1"
    local value="$2"
    if amixer -c $CARD cset name="$name" "$value" >/dev/null 2>&1; then
        echo -e "    ${GREEN}✓${NC}  $name = $value"
    else
        echo -e "    ${YELLOW}!${NC}  $name — not found"
    fi
}

get_ctl() {
    amixer -c $CARD cget name="$1" 2>/dev/null | grep ': values=' | sed 's/.*values=//'
}

# Map percentage (0–100) to digital gain value (0–84, where 84 = 0dB)
pct_to_rx_digital() {
    local pct="$1"
    echo $(( pct * 84 / 100 ))
}

# Map percentage (0–100) to TX decimator gain (0–20, where 20 = +20dB)
pct_to_tx_digital() {
    local pct="$1"
    echo $(( pct * 20 / 100 ))
}

# ── Detect sound card ───────────────────────────────────────────────────

check_card() {
    if [ ! -f /proc/asound/cards ]; then
        error "No ALSA subsystem found."
    fi
    if ! grep -q "card $CARD" /proc/asound/cards 2>/dev/null; then
        error "Sound card $CARD not found. Check: cat /proc/asound/cards"
    fi
}

# ── Configure headphone playback ────────────────────────────────────────

configure_playback() {
    local vol_pct="${1:-80}"
    local rx_dig=$(pct_to_rx_digital "$vol_pct")

    section "Headphone Playback Routing"

    info "DSP → CODEC DMA routing"
    set_ctl 'RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1' 1

    info "LPASS RX macro MUX → AIF1 Playback"
    set_ctl 'RX_MACRO RX0 MUX' 'AIF1_PB'
    set_ctl 'RX_MACRO RX1 MUX' 'AIF1_PB'

    info "Interpolators (signal path to DAC)"
    set_ctl 'RX INT0_1 MIX1 INP0' 'RX0'
    set_ctl 'RX INT1_1 MIX1 INP0' 'RX1'

    info "Demodulator → Class-H"
    set_ctl 'RX INT0 DEM MUX' 'CLSH_DSM_OUT'
    set_ctl 'RX INT1 DEM MUX' 'CLSH_DSM_OUT'

    info "Enable RDAC + headphone switches"
    set_ctl 'HPHL_RDAC Switch' 1
    set_ctl 'HPHR_RDAC Switch' 1
    set_ctl 'HPHL Switch' 1
    set_ctl 'HPHR Switch' 1

    info "Digital volume: ${vol_pct}% (register=${rx_dig}/84)"
    set_ctl 'RX_RX0 Digital' "$rx_dig"
    set_ctl 'RX_RX1 Digital' "$rx_dig"
}

# ── Configure microphone capture ────────────────────────────────────────

configure_capture() {
    local gain_pct="${1:-60}"
    local tx_dig=$(pct_to_tx_digital "$gain_pct")

    section "Microphone Capture Routing"

    info "CODEC DMA TX → DSP capture (MultiMedia1)"
    set_ctl 'MultiMedia1 Mixer TX_CODEC_DMA_TX_3' 1

    info "TX macro decimator → SoundWire mic"
    set_ctl 'TX DEC0 MUX' 'SWR_MIC'
    set_ctl 'TX SMIC MUX0' 'ADC2'

    info "ADC2 input select → INP3 (AMIC2 on Zephyria Shield)"
    set_ctl 'ADC2 MUX' 'INP3'

    info "TX capture path → AIF1"
    set_ctl 'TX_AIF1_CAP Mixer DEC0' 1

    info "Decimator gain: ${gain_pct}% (register=${tx_dig}/20)"
    set_ctl 'TX_DEC0' "$tx_dig"
}

# ── Set volume only ─────────────────────────────────────────────────────

set_volume() {
    local pct="$1"
    [ -z "$pct" ] && error "Usage: $0 volume <0-100>"
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    local rx_dig=$(pct_to_rx_digital "$pct")

    info "Headphone volume: ${pct}% (register=${rx_dig}/84)"
    set_ctl 'RX_RX0 Digital' "$rx_dig"
    set_ctl 'RX_RX1 Digital' "$rx_dig"
}

# ── Set mic gain only ───────────────────────────────────────────────────

set_mic_gain() {
    local pct="$1"
    [ -z "$pct" ] && error "Usage: $0 mic-gain <0-100>"
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    local tx_dig=$(pct_to_tx_digital "$pct")

    info "Mic gain: ${pct}% (register=${tx_dig}/20)"
    set_ctl 'TX_DEC0' "$tx_dig"
}

# ── Status ──────────────────────────────────────────────────────────────

show_status() {
    section "Audio Status"

    echo "  Sound card:"
    cat /proc/asound/cards 2>/dev/null | sed 's/^/    /'
    echo ""

    echo "  Playback routing:"
    local mm1_rx=$(get_ctl 'RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1')
    local hphl=$(get_ctl 'HPHL Switch')
    local hphr=$(get_ctl 'HPHR Switch')
    local rx0=$(get_ctl 'RX_RX0 Digital')
    local rx1=$(get_ctl 'RX_RX1 Digital')

    if [ "$mm1_rx" = "1" ] && [ "$hphl" = "1" ]; then
        echo -e "    ${GREEN}✓${NC}  MultiMedia1 → RX_CODEC_DMA_RX_0 → HPHL/HPHR"
        echo "    Volume L: ${rx0}/84  R: ${rx1}/84"
    else
        echo -e "    ${RED}✗${NC}  Playback routing not configured (run: $0)"
    fi
    echo ""

    echo "  Capture routing:"
    local mm1_tx=$(get_ctl 'MultiMedia1 Mixer TX_CODEC_DMA_TX_3')
    local dec0=$(get_ctl 'TX_DEC0')
    if [ "$mm1_tx" = "1" ]; then
        echo -e "    ${GREEN}✓${NC}  TX_CODEC_DMA_TX_3 → MultiMedia1"
        echo "    Mic gain: ${dec0}/20"
    else
        echo -e "    ${RED}✗${NC}  Capture routing not configured (run: $0)"
    fi
    echo ""

    echo "  Deferred probe issues:"
    if dmesg 2>/dev/null | grep -q 'deferred probe pending.*sound'; then
        echo -e "    ${RED}✗${NC}  Sound card has deferred probe failures"
        dmesg 2>/dev/null | grep 'deferred probe pending.*sound' | tail -1 | sed 's/^/        /'
    else
        echo -e "    ${GREEN}✓${NC}  No deferred probe issues"
    fi
    echo ""
}

# ── Main ────────────────────────────────────────────────────────────────

ACTION="${1:-setup}"

case "$ACTION" in
    setup)
        check_card

        echo ""
        echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"
        echo -e "${BOLD}  Audio Configuration — Arduino UNO Q / Zephyria Shield${NC}"
        echo -e "${BOLD}════════════════════════════════════════════════════════════${NC}"

        configure_playback "${2:-80}"
        configure_capture "${3:-60}"

        section "Done"

        echo "  Headphone: configured (${2:-80}% volume)"
        echo "  Microphone: configured (${3:-60}% gain)"
        echo ""
        echo "  Adjust later:"
        echo -e "    ${GREEN}$0 volume 50${NC}       # headphone 0–100%"
        echo -e "    ${GREEN}$0 mic-gain 80${NC}     # microphone 0–100%"
        echo -e "    ${GREEN}$0 status${NC}          # show current config"
        echo -e "    ${GREEN}$0 test${NC}            # quick playback test"
        echo ""
        echo "  Test commands:"
        echo -e "    ${GREEN}speaker-test -c 2 -t sine -f 440 -l 2${NC}"
        echo -e "    ${GREEN}arecord -d 5 -f cd -t wav /tmp/test.wav && aplay /tmp/test.wav${NC}"
        echo ""
        ;;

    volume)
        check_card
        set_volume "$2"
        ;;

    mic-gain)
        check_card
        set_mic_gain "$2"
        ;;

    status)
        check_card
        show_status
        ;;

    test)
        check_card
        info "Playing 440 Hz test tone (2 seconds)..."
        speaker-test -c 2 -t sine -f 440 -l 2
        ;;

    *)
        echo "Usage: $0 [setup|volume <0-100>|mic-gain <0-100>|status|test]"
        echo ""
        echo "  setup [vol%] [mic%]   Configure full routing (default: 80% vol, 60% mic)"
        echo "  volume <0-100>        Adjust headphone volume"
        echo "  mic-gain <0-100>      Adjust microphone gain"
        echo "  status                Show current audio configuration"
        echo "  test                  Play a test tone"
        exit 1
        ;;
esac
