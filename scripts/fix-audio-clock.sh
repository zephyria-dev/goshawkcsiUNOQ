#!/bin/bash
#
# Fix LPASS LPI pinctrl "Failed to get clk 'audio'" deferred probe failure
#
# Problem:
#   pinctrl@a7c0000 (lpass_tlmm) needs the "audio" clock from q6afecc,
#   which is a child of q6afe (APR service), which lives inside the ADSP
#   remoteproc. If the QDSP6 audio modules load too late, lpass_tlmm's
#   deferred probe times out and the entire audio subsystem fails:
#
#     platform a7c0000.pinctrl: deferred probe pending: Failed to get clk 'audio'
#     platform a740000.soundwire-controller: deferred probe pending
#     platform a610000.soundwire-controller: deferred probe pending
#     platform sound: deferred probe pending
#
# Root cause:
#   All audio modules are CONFIG_*=m (loadable). The dependency chain:
#     qcom_glink_smem → ADSP boots → qcom_apr → q6afe → q6afe-clocks (q6afecc)
#   If any module in this chain loads after deferred_probe_timeout (30s),
#   lpass_tlmm can never get its clock and permanently fails.
#
# Fix:
#   1. Load audio modules early via /etc/modules-load.d/
#   2. Optionally increase deferred_probe_timeout as safety margin
#
# Usage:
#   sudo ./fix-audio-clock.sh          # Apply fix
#   sudo ./fix-audio-clock.sh status   # Check current status
#   sudo ./fix-audio-clock.sh revert   # Remove fix
#

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

MODULES_CONF="/etc/modules-load.d/audio-clock-chain.conf"

# Modules in dependency order — these must load before deferred_probe_timeout
AUDIO_MODULES=(
    qcom_glink_smem    # GLINK transport to ADSP
    qcom_apr           # APR protocol (registers APR bus)
    snd_soc_qdsp6      # QDSP6 umbrella (pulls in q6afe, q6afe-clocks, etc.)
)

ACTION="${1:-apply}"

check_status() {
    echo ""
    echo -e "${BOLD}=== LPASS Audio Clock Status ===${NC}"
    echo ""

    # Check if lpass_tlmm probed successfully
    if [ -d /sys/bus/platform/drivers/qcom-sm6115-lpass-lpi-pinctrl/a7c0000.pinctrl ]; then
        echo -e "  ${GREEN}✓${NC}  lpass_tlmm (pinctrl@a7c0000) — probed OK"
    else
        if dmesg 2>/dev/null | grep -q "a7c0000.pinctrl.*deferred probe"; then
            echo -e "  ${RED}✗${NC}  lpass_tlmm (pinctrl@a7c0000) — deferred probe FAILED"
        else
            echo -e "  ${YELLOW}?${NC}  lpass_tlmm (pinctrl@a7c0000) — status unknown"
        fi
    fi

    # Check q6afecc
    if [ -d /sys/bus/platform/drivers/q6afe ]; then
        echo -e "  ${GREEN}✓${NC}  q6afe — loaded"
    else
        echo -e "  ${RED}✗${NC}  q6afe — not loaded"
    fi

    # Check loaded modules
    echo ""
    echo "  Module status:"
    for mod in "${AUDIO_MODULES[@]}"; do
        mod_under="${mod//-/_}"
        if lsmod 2>/dev/null | grep -q "^${mod_under}"; then
            echo -e "    ${GREEN}✓${NC}  $mod"
        else
            echo -e "    ${RED}✗${NC}  $mod (not loaded)"
        fi
    done

    # Check modules-load.d config
    echo ""
    if [ -f "$MODULES_CONF" ]; then
        echo -e "  ${GREEN}✓${NC}  $MODULES_CONF exists (early-load configured)"
    else
        echo -e "  ${YELLOW}!${NC}  $MODULES_CONF not found (early-load NOT configured)"
    fi

    # Check sound card
    echo ""
    if [ -f /proc/asound/cards ]; then
        local cards
        cards=$(cat /proc/asound/cards 2>/dev/null)
        if [ -n "$cards" ] && ! echo "$cards" | grep -q "no soundcards"; then
            echo -e "  ${GREEN}✓${NC}  Sound card(s) detected:"
            echo "$cards" | sed 's/^/        /'
        else
            echo -e "  ${RED}✗${NC}  No sound cards detected"
        fi
    fi

    # Check deferred probe timeout
    echo ""
    local timeout
    timeout=$(cat /sys/module/driver_core/parameters/deferred_probe_timeout 2>/dev/null || echo "unknown")
    echo "  Deferred probe timeout: ${timeout}s"

    echo ""
}

apply_fix() {
    echo ""
    echo -e "${BOLD}=== Applying LPASS Audio Clock Fix ===${NC}"
    echo ""

    # Step 1: Create modules-load.d config for early loading
    info "Creating $MODULES_CONF"

    cat > "$MODULES_CONF" << 'EOF'
# Load audio clock-chain modules early to prevent lpass_tlmm deferred probe failure.
# The pinctrl@a7c0000 (lpass_tlmm) needs the "audio" clock from q6afecc,
# which requires the full QDSP6 audio stack to be loaded before
# deferred_probe_timeout expires.
#
# Dependency chain:
#   qcom_glink_smem → ADSP remoteproc → qcom_apr → q6afe → q6afe-clocks
#
# See: scripts/fix-audio-clock.sh for details.

qcom_glink_smem
qcom_apr
snd_soc_qdsp6
EOF

    echo -e "  ${GREEN}✓${NC}  Created $MODULES_CONF"

    # Step 2: Try loading modules now (for immediate effect without reboot)
    info "Loading audio modules now..."
    local loaded=0
    for mod in "${AUDIO_MODULES[@]}"; do
        if modprobe "$mod" 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC}  modprobe $mod"
            loaded=$((loaded + 1))
        else
            warn "modprobe $mod failed (may need reboot)"
        fi
    done

    # Step 3: After loading modules, try to retrigger deferred probes
    if [ $loaded -gt 0 ]; then
        info "Retriggering deferred probes..."
        # Writing to /sys/bus/platform/drivers_probe can retrigger
        if [ -w /sys/bus/platform/drivers_probe ]; then
            echo "a7c0000.pinctrl" > /sys/bus/platform/drivers_probe 2>/dev/null || true
        fi
        # Alternative: unbind/rebind if driver exists
        if [ -d /sys/bus/platform/drivers/qcom-sm6115-lpass-lpi-pinctrl ]; then
            echo "a7c0000.pinctrl" > /sys/bus/platform/drivers/qcom-sm6115-lpass-lpi-pinctrl/unbind 2>/dev/null || true
            sleep 1
            echo "a7c0000.pinctrl" > /sys/bus/platform/drivers/qcom-sm6115-lpass-lpi-pinctrl/bind 2>/dev/null || true
        fi
    fi

    echo ""
    echo -e "${BOLD}Fix applied.${NC}"
    echo ""
    echo "  A reboot is recommended for the fix to take full effect."
    echo "  The modules will now load early on every boot."
    echo ""
    echo "  After reboot, verify with:"
    echo "    dmesg | grep -E 'a7c0000|q6afe|lpass'"
    echo "    cat /proc/asound/cards"
    echo ""
}

revert_fix() {
    echo ""
    echo -e "${BOLD}=== Reverting LPASS Audio Clock Fix ===${NC}"
    echo ""

    if [ -f "$MODULES_CONF" ]; then
        rm -f "$MODULES_CONF"
        echo -e "  ${GREEN}✓${NC}  Removed $MODULES_CONF"
    else
        info "Nothing to revert — $MODULES_CONF not found"
    fi

    echo ""
    echo "  Reboot to apply. Audio modules will load at default time."
    echo ""
}

case "$ACTION" in
    apply)
        [ "$(id -u)" -eq 0 ] || error "Run as root: sudo $0"
        apply_fix
        check_status
        ;;
    status)
        check_status
        ;;
    revert)
        [ "$(id -u)" -eq 0 ] || error "Run as root: sudo $0 revert"
        revert_fix
        ;;
    *)
        echo "Usage: $0 [apply|status|revert]"
        exit 1
        ;;
esac
