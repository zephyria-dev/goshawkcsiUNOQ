#!/bin/bash
#
# Build DSI Display Kernel Modules for Arduino UNO Q (QRB2210 / QCM2290)
#
# Builds out-of-tree loadable modules (.ko) for common DSI panel drivers
# used in the RPi ecosystem. No kernel replacement required.
#
# Supported modules:
#   tc358762  - DSI-to-DPI bridge (RPi 7", Freenove 4.3", WaveShare DSI)
#   ili9881c  - ILITEK ILI9881C panel (WaveShare 5"/7"/10.1")
#   st7701    - Sitronix ST7701 panel (Arduino GigaDisplay, HyperPixel 4)
#   hx8394    - Himax HX8394 panel (various 720p budget displays)
#   otm8009a  - Orise OTM8009A panel (STM32 Discovery, eval boards)
#   goodix_ts - Goodix GT911/GT9xx touch (polling mode, no IRQ required)
#
# Usage:
#   ./build-dsi-modules.sh [module|all]
#
#   ./build-dsi-modules.sh all          # Build all modules
#   ./build-dsi-modules.sh tc358762     # Build only tc358762
#   ./build-dsi-modules.sh ili9881c     # Build only ili9881c
#
# Run on the Arduino UNO Q target, OR cross-compile:
#   ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- KERNEL_DIR=/path/to/kernel \
#     ./build-dsi-modules.sh all
#

set -e

# ── Configuration ─────────────────────────────────────────────────────────────
#
# Target kernel info:
#   Version : 6.16.7-g0dd6551ae96b
#   Repo    : https://github.com/arduino/linux-qcom
#   Branch  : tag matching 6.16.7 build

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK_DIR="/tmp/dsi-modules-build"
KERNEL_VERSION="${KERNEL_VERSION:-$(uname -r 2>/dev/null || echo "unknown")}"
KERNEL_DIR="${KERNEL_DIR:-/lib/modules/${KERNEL_VERSION}/build}"
ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"

# Source fetch: pull driver files from the Arduino linux-qcom repo.
# The kernel running on the device is 6.16.7-g0dd6551ae96b built from
# https://github.com/arduino/linux-qcom
# Default branch is "main"; override with LINUX_TAG if a specific tag exists.
LINUX_REPO_RAW="${LINUX_REPO_RAW:-https://raw.githubusercontent.com/arduino/linux-qcom/main}"

# Fallback: upstream Linus tree at matching version for driver sources
# (arduino/linux-qcom may not carry panel drivers; fallback ensures we get them)
LINUX_TAG="${LINUX_TAG:-v6.16}"
LINUX_UPSTREAM_RAW="https://raw.githubusercontent.com/torvalds/linux/${LINUX_TAG}"

# fetch_url: try arduino repo first, fall back to upstream torvalds tree
fetch_url() {
    local path="$1"
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

    if curl -fsSL "${LINUX_REPO_RAW}/${path}" -o "$dest" 2>/dev/null; then
        return 0
    fi
    curl -fsSL "${LINUX_UPSTREAM_RAW}/${path}" -o "$dest"
}

# ── Color output ──────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }

# ── Module definitions ────────────────────────────────────────────────────────
#
# Format: MODULE_SOURCES_<name>="src1.c[:dest1.c] src2.c[:dest2.c] ..."
# Format: MODULE_INSTALL_<name>="kernel/drivers/gpu/drm/..."
# Format: MODULE_DEPENDS_<name>="drm drm_mipi_dsi panel_simple"  (modprobe deps)
#
# tc358762 - DSI-to-DPI bridge (Toshiba)
MODULE_SOURCES_tc358762="drivers/gpu/drm/bridge/tc358762.c"
MODULE_INSTALL_tc358762="kernel/drivers/gpu/drm/bridge"
MODULE_DEPENDS_tc358762="drm drm_kms_helper"

# ili9881c - ILITEK ILI9881C panel driver
MODULE_SOURCES_ili9881c="drivers/gpu/drm/panel/panel-ilitek-ili9881c.c:ili9881c.c"
MODULE_INSTALL_ili9881c="kernel/drivers/gpu/drm/panel"
MODULE_DEPENDS_ili9881c="drm drm_kms_helper drm_mipi_dsi backlight"

# st7701 - Sitronix ST7701 panel driver
MODULE_SOURCES_st7701="drivers/gpu/drm/panel/panel-sitronix-st7701.c:st7701.c"
MODULE_INSTALL_st7701="kernel/drivers/gpu/drm/panel"
MODULE_DEPENDS_st7701="drm drm_kms_helper drm_mipi_dsi backlight"

# hx8394 - Himax HX8394 panel driver
MODULE_SOURCES_hx8394="drivers/gpu/drm/panel/panel-himax-hx8394.c:hx8394.c"
MODULE_INSTALL_hx8394="kernel/drivers/gpu/drm/panel"
MODULE_DEPENDS_hx8394="drm drm_kms_helper drm_mipi_dsi backlight"

# otm8009a - Orise OTM8009A panel driver
MODULE_SOURCES_otm8009a="drivers/gpu/drm/panel/panel-orisetech-otm8009a.c:otm8009a.c"
MODULE_INSTALL_otm8009a="kernel/drivers/gpu/drm/panel"
MODULE_DEPENDS_otm8009a="drm drm_kms_helper drm_mipi_dsi backlight"


# panel_dpi - Generic DPI panel with DT-defined timings (for TC358762 downstream LCD)
MODULE_SOURCES_panel_dpi="drivers/gpu/drm/panel/panel-dpi.c:panel_dpi.c"
MODULE_INSTALL_panel_dpi="kernel/drivers/gpu/drm/panel"
MODULE_DEPENDS_panel_dpi="drm drm_kms_helper"

# goodix_ts - Goodix GT911/GT9xx touchscreen (patched with polling mode)
# Stock kernel has CONFIG_TOUCHSCREEN_GOODIX=m but the built-in module requires IRQ.
# This patched version adds input_setup_polling() fallback when client->irq == 0
# (e.g. INT pin routed to STM32 domain, not Linux GPIO).
# Note: goodix.h is fetched as an extra header (not compiled)
MODULE_SOURCES_goodix_ts="drivers/input/touchscreen/goodix.c drivers/input/touchscreen/goodix_fwupload.c"
MODULE_HEADERS_goodix_ts="drivers/input/touchscreen/goodix.h"
MODULE_INSTALL_goodix_ts="kernel/drivers/input/touchscreen"
MODULE_DEPENDS_goodix_ts=""

ALL_MODULES="tc358762 panel_dpi ili9881c st7701 hx8394 otm8009a goodix_ts"

# ── Helper functions ──────────────────────────────────────────────────────────

check_prerequisites() {
    step "Checking prerequisites"

    if [ "$EUID" -eq 0 ]; then
        error "Do not run as root. Script uses sudo when required."
    fi

    # Build tools
    for tool in make curl; do
        if ! command -v "$tool" &>/dev/null; then
            warn "$tool not found, attempting install..."
            sudo apt-get install -y build-essential curl
            break
        fi
    done

    # Kernel headers / build dir
    if [ ! -d "$KERNEL_DIR" ]; then
        warn "Kernel build dir not found: $KERNEL_DIR"
        info "Attempting: sudo apt-get install linux-headers-${KERNEL_VERSION}"
        if ! sudo apt-get install -y "linux-headers-${KERNEL_VERSION}" 2>/dev/null; then
            echo ""
            echo "  Kernel headers are NOT available via apt for ${KERNEL_VERSION}."
            echo ""
            echo "  Options:"
            echo "   A) Cross-compile on a host PC:"
            echo "      export ARCH=arm64"
            echo "      export CROSS_COMPILE=aarch64-linux-gnu-"
            echo "      export KERNEL_DIR=/path/to/arduino-linux-source"
            echo "      ./build-dsi-modules.sh all"
            echo ""
            echo "   B) Build from Arduino kernel source on-device:"
            echo "      git clone --depth=1 https://github.com/arduino/linux-qcom.git"
            echo "      cd linux-qcom && make ARCH=arm64 defconfig"
            echo "      make ARCH=arm64 scripts prepare modules_prepare"
            echo "      KERNEL_DIR=\$(pwd) ./build-dsi-modules.sh all"
            error "Cannot continue without kernel headers."
        fi
    fi

    info "Kernel build dir: $KERNEL_DIR"
}

fetch_source() {
    local mod="$1"
    local build_dir="$2"
    local sources_var="MODULE_SOURCES_${mod}"
    local sources="${!sources_var}"
    local headers_var="MODULE_HEADERS_${mod}"
    local headers="${!headers_var}"

    info "Fetching sources for ${mod}..."

    for entry in $sources $headers; do
        local src="${entry%%:*}"
        local dst="${entry##*:}"
        # If no ':' separator, dst == src basename
        [ "$dst" = "$entry" ] && dst="$(basename "$src")"

        info "  GET ${src}"
        info "    1st try : ${LINUX_REPO_RAW}/${src}"
        info "    fallback: ${LINUX_UPSTREAM_RAW}/${src}"

        if ! fetch_url "$src" "${build_dir}/${dst}"; then
            error "Failed to download ${src} from both arduino/linux-qcom and torvalds/linux"
        fi
    done
}

write_kbuild() {
    local mod="$1"
    local build_dir="$2"
    local sources_var="MODULE_SOURCES_${mod}"
    local sources="${!sources_var}"

    # Collect object names (*.o from each *.c destination)
    local objs=""
    for entry in $sources; do
        local dst="${entry##*:}"
        [ "$dst" = "$entry" ] && dst="$(basename "${entry%%:*}")"
        objs="${objs} ${dst%.c}.o"
    done

    cat > "${build_dir}/Kbuild" << EOF
# Kbuild — out-of-tree module: ${mod}
obj-m := ${mod}.o
EOF

    # If multiple source files, list them as part of compound module
    local count
    count=$(echo "$objs" | wc -w)
    if [ "$count" -gt 1 ]; then
        cat >> "${build_dir}/Kbuild" << EOF
${mod}-objs :=${objs}
EOF
    fi
}

write_makefile() {
    local build_dir="$1"

    cat > "${build_dir}/Makefile" << 'MAKEFILE'
ARCH                 ?= arm64
CROSS_COMPILE        ?=
KERNEL_DIR           ?= /lib/modules/$(shell uname -r)/build
# KBUILD_MODPOST_WARN=1 turns unresolved-symbol errors into warnings.
# Needed when cross-compiling against a source tree with no Module.symvers
# (i.e. headers-only prep without a full 'make modules' run).
# The missing symbols are built into the target kernel and resolve at runtime.
KBUILD_MODPOST_WARN  ?= 0
PWD                  := $(shell pwd)

all:
	$(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
	        KBUILD_MODPOST_WARN=$(KBUILD_MODPOST_WARN) \
	        -C $(KERNEL_DIR) M=$(PWD) modules

clean:
	$(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) \
	        -C $(KERNEL_DIR) M=$(PWD) clean

.PHONY: all clean
MAKEFILE
}

build_module() {
    local mod="$1"
    local build_dir="${WORK_DIR}/${mod}"

    step "Building module: ${mod}"

    mkdir -p "$build_dir"

    fetch_source "$mod" "$build_dir"
    write_kbuild  "$mod" "$build_dir"
    write_makefile       "$build_dir"

    info "Compiling..."
    if ! make -C "$build_dir" ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
              KERNEL_DIR="$KERNEL_DIR" \
              KBUILD_MODPOST_WARN="${KBUILD_MODPOST_WARN:-0}"; then
        echo ""
        warn "Build failed for ${mod}. See errors above."
        echo ""
        echo "  Common causes:"
        echo "    - Kernel header version mismatch (source != running kernel)"
        echo "    - Missing kernel config option (check if DRM_MIPI_DSI=y)"
        echo "    - Source incompatibility (try LINUX_TAG=v<your-kernel-version>)"
        return 1
    fi

    local ko="${build_dir}/${mod}.ko"
    if [ ! -f "$ko" ]; then
        warn "${mod}.ko not found after build (may be named differently)"
        # Try to find it
        ko=$(find "$build_dir" -name "*.ko" | head -1)
        [ -z "$ko" ] && return 1
    fi

    info "Built: $ko"
    ls -lh "$ko"
    return 0
}

install_module() {
    local mod="$1"
    local build_dir="${WORK_DIR}/${mod}"
    local install_var="MODULE_INSTALL_${mod}"
    local install_subdir="${!install_var}"

    local install_dir="/lib/modules/${KERNEL_VERSION}/${install_subdir}"

    step "Installing module: ${mod} → ${install_dir}"

    local ko
    ko=$(find "$build_dir" -name "${mod}.ko" | head -1)
    [ -z "$ko" ] && ko=$(find "$build_dir" -name "*.ko" | head -1)
    [ -z "$ko" ] && { warn "No .ko found for ${mod}"; return 1; }

    sudo mkdir -p "$install_dir"
    sudo cp "$ko" "${install_dir}/"
    sudo depmod -a

    info "Installed: ${install_dir}/$(basename "$ko")"
}

load_module() {
    local mod="$1"
    local depends_var="MODULE_DEPENDS_${mod}"
    local depends="${!depends_var}"

    step "Loading module: ${mod}"

    # Load dependencies first (best-effort)
    for dep in $depends; do
        sudo modprobe "$dep" 2>/dev/null || true
    done

    if sudo modprobe "$mod"; then
        info "Module ${mod} loaded successfully"
    else
        warn "modprobe ${mod} failed — may need device tree configuration first"
        info "You can load it manually after applying the device tree:"
        info "  sudo modprobe ${mod}"
    fi
}

show_summary() {
    local built=("$@")
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  DSI Module Build Summary"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    for mod in "${built[@]}"; do
        local ko
        ko=$(find "${WORK_DIR}/${mod}" -name "*.ko" 2>/dev/null | head -1)
        if [ -n "$ko" ]; then
            echo -e "  ${GREEN}✓${NC} ${mod}.ko"
        else
            echo -e "  ${RED}✗${NC} ${mod}  (build failed)"
        fi
    done
    echo ""
    echo "  Next steps:"
    echo "   1. Apply the Freenove display device tree overlay:"
    echo "      sudo cp dts/imola-camera-dsi.dts /boot/efi/dtb/qcom/"
    echo "   2. Verify module is loaded:"
    echo "      lsmod | grep tc358762"
    echo "   3. Check display pipeline:"
    echo "      dmesg | grep -iE 'dsi|panel|tc358762|display'"
    echo "   4. Check DRM devices:"
    echo "      ls /dev/dri/  &&  cat /sys/class/drm/card*/status"
    echo ""
    echo "  Build artifacts: ${WORK_DIR}/"
    echo ""
}

usage() {
    echo "Usage: $0 [MODULE|all]"
    echo ""
    echo "  all          Build all supported modules"
    echo "  tc358762     DSI-to-DPI bridge (RPi 7\", Freenove 4.3\")"
    echo "  ili9881c     ILITEK ILI9881C panel (WaveShare 5\"/7\"/10.1\")"
    echo "  st7701       Sitronix ST7701 panel (Arduino GigaDisplay)"
    echo "  hx8394       Himax HX8394 panel (720p budget displays)"
    echo "  otm8009a     Orise OTM8009A panel (STM32 Discovery boards)"
    echo "  goodix_ts    Goodix GT911/GT9xx touchscreen (polling mode, no IRQ)"
    echo ""
    echo "  Environment variables:"
    echo "    KERNEL_DIR            Path to kernel build dir (default: /lib/modules/\$(uname -r)/build)"
    echo "    KERNEL_VERSION        Target kernel version string (default: \$(uname -r))"
    echo "    ARCH                  Target architecture (default: arm64)"
    echo "    CROSS_COMPILE         Cross-compiler prefix (default: none)"
    echo "    SKIP_INSTALL          Set to 1 to skip install/modprobe (cross-build mode)"
    echo "    KBUILD_MODPOST_WARN   Set to 1 to allow build without Module.symvers"
    echo "    LINUX_TAG             Linux git tag for source fetch (default: v6.16)"
    echo ""
    echo "  Cross-compile example:"
    echo "    ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \\"
    echo "    KERNEL_DIR=/path/to/linux \\"
    echo "    LINUX_TAG=v6.16 \\"
    echo "    ./build-dsi-modules.sh all"
}

# ── Main ──────────────────────────────────────────────────────────────────────

TARGET="${1:-}"

if [ -z "$TARGET" ] || [ "$TARGET" = "-h" ] || [ "$TARGET" = "--help" ]; then
    usage
    exit 0
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  DSI Display Module Builder for Arduino UNO Q"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "  Kernel : ${KERNEL_VERSION}"
echo "  Build  : ${KERNEL_DIR}"
echo "  Arch   : ${ARCH}"
echo "  Cross  : ${CROSS_COMPILE:-<native>}"
echo ""

check_prerequisites

mkdir -p "$WORK_DIR"

if [ "$TARGET" = "all" ]; then
    MODULES_TO_BUILD=($ALL_MODULES)
else
    # Validate module name
    if [[ ! " $ALL_MODULES " =~ " $TARGET " ]]; then
        error "Unknown module: '$TARGET'. Supported: $ALL_MODULES"
    fi
    MODULES_TO_BUILD=("$TARGET")
fi

BUILT=()
for mod in "${MODULES_TO_BUILD[@]}"; do
    if build_module "$mod"; then
        # Skip install/load when cross-compiling — the caller (cross-build script)
        # collects the .ko files and the user deploys them to the target manually.
        if [ "${SKIP_INSTALL:-0}" = "1" ]; then
            info "Cross-build mode: skipping install/load for ${mod}"
        else
            install_module "$mod"
            load_module    "$mod"
        fi
        BUILT+=("$mod")
    else
        warn "Skipping install/load for failed module: ${mod}"
        BUILT+=("${mod}-FAILED")
    fi
done

show_summary "${BUILT[@]}"
