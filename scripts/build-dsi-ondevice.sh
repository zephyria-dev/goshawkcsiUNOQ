#!/bin/bash
#
# Build and install DSI display kernel modules directly on the Arduino UNO Q
#
# Run this script on the board itself. No cross-compiler needed.
#
# Usage:
#   ./build-dsi-ondevice.sh [MODULE|all] [KERNEL_SRC_DIR]
#
#   ./build-dsi-ondevice.sh tc358762                              # default src dir
#   ./build-dsi-ondevice.sh tc358762 /home/arduino/inspection/arduino-linux-qcom
#   ./build-dsi-ondevice.sh all      /home/arduino/inspection/arduino-linux-qcom
#
# The script will:
#   1. Find or prepare kernel headers (clones arduino/linux-qcom if needed)
#   2. Download driver source from arduino/linux-qcom or torvalds/linux
#   3. Compile the .ko module
#   4. Install it under /lib/modules/$(uname -r)/
#   5. Run depmod and optionally modprobe
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ─────────────────────────────────────────────────────────────

KVER="$(uname -r)"
WORK_DIR="/tmp/dsi-ondevice-build"
KERNEL_HEADERS="/lib/modules/${KVER}/build"

# Kernel source directory — override via 2nd argument or KERNEL_SRC_DIR env var.
# Default is /opt/arduino-linux-qcom; the repo is cloned here automatically
# if no headers are found elsewhere.
KERNEL_SRC_DIR="${2:-${KERNEL_SRC_DIR:-/opt/arduino-linux-qcom}}"

ARDUINO_LINUX_REPO="https://github.com/arduino/linux-qcom.git"

# Source fetch: try arduino/linux-qcom first, fall back to torvalds/linux v6.16
ARDUINO_RAW="https://raw.githubusercontent.com/arduino/linux-qcom/main"
UPSTREAM_RAW="https://raw.githubusercontent.com/torvalds/linux/v6.16"

# BUILD_DIR is set by find_or_prepare_headers()
BUILD_DIR=""

# BUILT_KO is set by build_module() instead of using stdout capture
BUILT_KO=""

# ── Driver source paths ───────────────────────────────────────────────────────

SOURCES_tc358762="drivers/gpu/drm/bridge/tc358762.c"
INSTALL_tc358762="kernel/drivers/gpu/drm/bridge"

SOURCES_ili9881c="drivers/gpu/drm/panel/panel-ilitek-ili9881c.c:ili9881c.c"
INSTALL_ili9881c="kernel/drivers/gpu/drm/panel"

SOURCES_st7701="drivers/gpu/drm/panel/panel-sitronix-st7701.c:st7701.c"
INSTALL_st7701="kernel/drivers/gpu/drm/panel"

SOURCES_hx8394="drivers/gpu/drm/panel/panel-himax-hx8394.c:hx8394.c"
INSTALL_hx8394="kernel/drivers/gpu/drm/panel"

SOURCES_otm8009a="drivers/gpu/drm/panel/panel-orisetech-otm8009a.c:otm8009a.c"
INSTALL_otm8009a="kernel/drivers/gpu/drm/panel"


SOURCES_panel_dpi="drivers/gpu/drm/panel/panel-dpi.c:panel_dpi.c"
INSTALL_panel_dpi="kernel/drivers/gpu/drm/panel"

ALL_MODULES="tc358762 panel_dpi ili9881c st7701 hx8394 otm8009a"

# ── Helpers ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }

fetch_file() {
    local src_path="$1"
    local dest="$2"
    local basename
    basename="$(basename "$dest")"

    # Check for local source override in scripts/src/
    local local_src="${SCRIPT_DIR}/src/${basename}"
    if [ -f "$local_src" ]; then
        info "  Using local source: ${local_src}"
        cp "$local_src" "$dest"
        return 0
    fi

    if curl -fsSL "${ARDUINO_RAW}/${src_path}" -o "$dest" 2>/dev/null; then
        return 0
    fi
    curl -fsSL "${UPSTREAM_RAW}/${src_path}" -o "$dest"
}

# ── Step 1: Prerequisites ─────────────────────────────────────────────────────

check_tools() {
    step "Checking tools"
    local need_install=()
    for t in make curl gcc; do
        command -v "$t" &>/dev/null || need_install+=("$t")
    done
    if [ ${#need_install[@]} -gt 0 ]; then
        info "Installing: ${need_install[*]}"
        sudo apt-get install -y build-essential curl
    fi
    info "Tools OK  (gcc: $(gcc --version | head -1))"
}

# ── Step 2: Kernel headers ────────────────────────────────────────────────────

find_or_prepare_headers() {
    step "Locating kernel headers for ${KVER}"

    # Best case: symlink /lib/modules/<kver>/build already points to headers
    if [ -f "${KERNEL_HEADERS}/Makefile" ]; then
        info "Headers found: ${KERNEL_HEADERS}"
        BUILD_DIR="${KERNEL_HEADERS}"
        return
    fi

    # Try apt
    info "Headers not in /lib/modules — trying apt..."
    if sudo apt-get install -y "linux-headers-${KVER}" 2>/dev/null \
       && [ -f "${KERNEL_HEADERS}/Makefile" ]; then
        info "Installed via apt: ${KERNEL_HEADERS}"
        BUILD_DIR="${KERNEL_HEADERS}"
        return
    fi

    # Use existing kernel source directory if already prepared
    if [ -f "${KERNEL_SRC_DIR}/Makefile" ] && \
       [ -f "${KERNEL_SRC_DIR}/scripts/mod/modpost" ]; then
        info "Using prepared kernel source: ${KERNEL_SRC_DIR}"
        BUILD_DIR="${KERNEL_SRC_DIR}"
        return
    fi

    # Clone arduino/linux-qcom and prepare headers in-tree
    warn "No pre-built headers for ${KVER}."
    warn "Preparing from source at: ${KERNEL_SRC_DIR}"
    warn "This is a one-time operation. On subsequent runs the source is reused."
    echo ""

    if [ ! -d "${KERNEL_SRC_DIR}/.git" ]; then
        info "Cloning arduino/linux-qcom (shallow) into ${KERNEL_SRC_DIR}..."
        mkdir -p "$(dirname "${KERNEL_SRC_DIR}")"
        git clone --depth=1 "$ARDUINO_LINUX_REPO" "$KERNEL_SRC_DIR"
    else
        info "Kernel source already present at ${KERNEL_SRC_DIR} — reusing."
    fi

    cd "$KERNEL_SRC_DIR"

    info "Configuring..."
    make ARCH=arm64 defconfig

    local cfgs=(
        CONFIG_DRM_TOSHIBA_TC358762=m
        CONFIG_DRM_PANEL_ILITEK_ILI9881C=m
        CONFIG_DRM_PANEL_SITRONIX_ST7701=m
        CONFIG_DRM_PANEL_HIMAX_HX8394=m
        CONFIG_DRM_PANEL_ORISETECH_OTM8009A=m
        CONFIG_DRM_MIPI_DSI=y
        CONFIG_BACKLIGHT_CLASS_DEVICE=y
    )
    for c in "${cfgs[@]}"; do
        scripts/config --set-val "${c%=*}" "${c#*=}"
    done
    make ARCH=arm64 olddefconfig

    info "Preparing headers..."
    make ARCH=arm64 -j"$(nproc)" scripts prepare
    make ARCH=arm64 -j"$(nproc)" modules_prepare

    # Seed empty Module.symvers to suppress the missing-file warning in modpost.
    # Unresolved symbol warnings are expected and suppressed by KBUILD_MODPOST_WARN=1.
    touch "${KERNEL_SRC_DIR}/Module.symvers"

    BUILD_DIR="${KERNEL_SRC_DIR}"
    info "Headers ready: ${BUILD_DIR}"
}

# ── Step 3: Build one module ──────────────────────────────────────────────────

# Sets global BUILT_KO to the path of the produced .ko file.
# Does NOT use stdout so callers can simply call build_module without
# command substitution ($(...)) — which would swallow all output.
build_module() {
    local mod="$1"
    local dir="${WORK_DIR}/${mod}"
    local sources_var="SOURCES_${mod}"
    local sources="${!sources_var}"

    step "Building: ${mod}"
    mkdir -p "$dir"

    for entry in $sources; do
        local src="${entry%%:*}"
        local dst="${entry##*:}"
        [ "$dst" = "$entry" ] && dst="$(basename "$src")"
        info "  Fetching ${src}"
        fetch_file "$src" "${dir}/${dst}" || error "Cannot fetch ${src}"
    done

    cat > "${dir}/Kbuild" << EOF
obj-m := ${mod}.o
EOF

    cat > "${dir}/Makefile" << MAKEFILE
ARCH ?= arm64
KDIR ?= ${BUILD_DIR}
PWD  := \$(shell pwd)

all:
	\$(MAKE) ARCH=\$(ARCH) KBUILD_MODPOST_WARN=1 -C \$(KDIR) M=\$(PWD) modules

clean:
	\$(MAKE) ARCH=\$(ARCH) -C \$(KDIR) M=\$(PWD) clean

.PHONY: all clean
MAKEFILE

    make -C "$dir" ARCH=arm64 KDIR="$BUILD_DIR" \
        || error "Build failed for ${mod}."

    BUILT_KO="$(find "$dir" -maxdepth 1 -name "*.ko" | head -1)"
    [ -z "$BUILT_KO" ] && error "No .ko produced for ${mod}"

    info "Built: ${BUILT_KO}  ($(du -sh "$BUILT_KO" | cut -f1))"
}

# ── Step 4: Install one module ────────────────────────────────────────────────

install_module() {
    local mod="$1"
    local ko="$2"
    local install_var="INSTALL_${mod}"
    local subdir="${!install_var}"
    local dest="/lib/modules/${KVER}/${subdir}"

    step "Installing: ${mod} → ${dest}"
    sudo mkdir -p "$dest"
    sudo cp "$ko" "${dest}/"
    sudo depmod -a
    info "Installed: ${dest}/$(basename "$ko")"
}

# ── Step 5: Load module ───────────────────────────────────────────────────────

load_module() {
    local mod="$1"
    if sudo modprobe "$mod" 2>/dev/null; then
        info "Loaded: ${mod}"
    else
        warn "modprobe ${mod} failed — apply device tree first, then reload."
        info "  sudo modprobe ${mod}"
    fi
}

# ── Summary ───────────────────────────────────────────────────────────────────

show_summary() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  Build complete"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    for mod in "$@"; do
        local ko
        ko=$(find "${WORK_DIR}/${mod}" -maxdepth 1 -name "*.ko" 2>/dev/null | head -1)
        if [ -n "$ko" ]; then
            if lsmod | grep -q "^${mod} "; then
                echo -e "  ${GREEN}✓${NC}  ${mod}.ko  →  loaded"
            else
                echo -e "  ${GREEN}✓${NC}  ${mod}.ko  →  installed (not yet loaded)"
            fi
        else
            echo -e "  ${RED}✗${NC}  ${mod}  (build failed)"
        fi
    done
    echo ""
    echo "  Next steps:"
    echo "   1. Compile and apply the Freenove display overlay:"
    echo "      dtc -@ -I dts -O dtb -o imola-camera-dsi-freenove.dtbo \\"
    echo "          dts/imola-camera-dsi-freenove.dts"
    echo "      fdtoverlay -i /boot/efi/dtb/qcom/imola-camera-shield.dtb \\"
    echo "                 -o /boot/efi/dtb/qcom/imola-camera-dsi-freenove.dtb \\"
    echo "                 imola-camera-dsi-freenove.dtbo"
    echo "   2. Set boot DTB and reboot"
    echo "   3. Check display pipeline:"
    echo "      dmesg | grep -iE 'dsi|panel|tc358762|display'"
    echo "      ls /dev/dri/"
    echo ""
}

# ── Usage ─────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [MODULE|all] [KERNEL_SRC_DIR]"
    echo ""
    echo "  MODULE       One of: tc358762 panel_dpi ili9881c st7701 hx8394 otm8009a"
    echo "  all          Build and install all supported modules"
    echo "  KERNEL_SRC_DIR  Path to prepared kernel source tree (optional)"
    echo "               Default: /opt/arduino-linux-qcom"
    echo "               Override: pass as 2nd argument or set env var"
    echo ""
    echo "Examples:"
    echo "  $0 tc358762"
    echo "  $0 tc358762 /home/arduino/inspection/arduino-linux-qcom"
    echo "  $0 all      /home/arduino/inspection/arduino-linux-qcom"
    echo ""
    echo "  # Or via environment variable:"
    echo "  KERNEL_SRC_DIR=/home/arduino/inspection/arduino-linux-qcom $0 all"
    echo ""
    echo "Modules:"
    echo "  tc358762   Freenove 4.3\" / RPi 7\" / WaveShare DSI"
    echo "  ili9881c   WaveShare 5\"/7\"/10.1\""
    echo "  st7701     Arduino GigaDisplay / HyperPixel 4"
    echo "  hx8394     Generic 720p budget DSI panels"
    echo "  otm8009a   STM32 Discovery / eval boards"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

TARGET="${1:-}"
if [ -z "$TARGET" ] || [ "$TARGET" = "-h" ] || [ "$TARGET" = "--help" ]; then
    usage; exit 0
fi

[ "$EUID" -eq 0 ] && error "Do not run as root. Script uses sudo internally."

case "$TARGET" in
    all) MODULES=($ALL_MODULES) ;;
    tc358762|panel_dpi|ili9881c|st7701|hx8394|otm8009a) MODULES=("$TARGET") ;;
    *) error "Unknown module '${TARGET}'. Run $0 --help for options." ;;
esac

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  DSI Module Builder — Arduino UNO Q  (on-device)"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Board kernel  : ${KVER}"
echo "  Kernel source : ${KERNEL_SRC_DIR}"
echo "  Modules       : ${MODULES[*]}"
echo ""

check_tools
find_or_prepare_headers
mkdir -p "$WORK_DIR"

BUILT=()
for mod in "${MODULES[@]}"; do
    build_module "$mod"          # sets BUILT_KO
    install_module "$mod" "$BUILT_KO"
    load_module    "$mod"
    BUILT+=("$mod")
done

show_summary "${BUILT[@]}"
