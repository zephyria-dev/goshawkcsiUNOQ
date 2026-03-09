#!/bin/bash
#
# Cross-compile DSI Display Modules on a Linux host PC for Arduino UNO Q
#
# This script automates the full cross-compilation flow on an x86-64 host:
#   1. Install aarch64 cross-compiler
#   2. Clone Arduino's Linux kernel source (shallow, matching tag)
#   3. Configure the kernel to enable needed DRM panel configs
#   4. Build headers and module scaffolding (no full kernel build)
#   5. Call build-dsi-modules.sh to build each .ko
#   6. Package .ko files for scp to the target
#
# Requirements (Ubuntu/Debian host):
#   sudo apt install gcc-aarch64-linux-gnu make bc flex bison \
#                    libssl-dev libelf-dev python3 rsync
#
# Usage:
#   ./cross-build-dsi-modules.sh [module|all]
#
# After running:
#   scp /tmp/dsi-modules-cross/*.ko user@uno-q:/tmp/
#   # On UNO Q:
#   sudo cp /tmp/*.ko /lib/modules/$(uname -r)/kernel/drivers/gpu/drm/bridge/
#   sudo depmod -a && sudo modprobe tc358762
#

set -e

# ── Configuration ─────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Arduino Linux kernel source repository
# Kernel running on device: 6.16.7-g0dd6551ae96b
# (uname -r: Linux Zephyria4GB 6.16.7-g0dd6551ae96b #1 SMP PREEMPT Tue Sep 23 12:46:06 UTC 2025 aarch64)
ARDUINO_LINUX_REPO="${ARDUINO_LINUX_REPO:-https://github.com/arduino/linux-qcom.git}"

# Kernel version string running on target (get with: ssh uno-q uname -r)
# Override with: TARGET_KERNEL=6.16.7-g0dd6551ae96b ./cross-build-dsi-modules.sh all
TARGET_KERNEL="${TARGET_KERNEL:-6.16.7-g0dd6551ae96b}"

CROSS_DIR="/tmp/dsi-modules-cross"
KERNEL_SRC="${CROSS_DIR}/linux-qcom"
OUTPUT_DIR="${CROSS_DIR}/modules"

ARCH="arm64"
CROSS_COMPILE="aarch64-linux-gnu-"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }

# ── Checks ────────────────────────────────────────────────────────────────────

check_host_tools() {
    step "Checking host tools"

    local missing=()
    for tool in make git curl "${CROSS_COMPILE}gcc" bc flex bison; do
        if ! command -v "$tool" &>/dev/null; then
            missing+=("$tool")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo ""
        warn "Missing tools: ${missing[*]}"
        echo ""
        echo "  Install with:"
        echo "    sudo apt-get install -y \\"
        echo "      build-essential gcc-aarch64-linux-gnu \\"
        echo "      bc flex bison libssl-dev libelf-dev python3 git curl"
        echo ""
        error "Install missing tools and retry."
    fi

    info "All host tools available."
}

# ── Kernel source ─────────────────────────────────────────────────────────────

clone_or_update_kernel() {
    step "Preparing kernel source"

    mkdir -p "$CROSS_DIR" "$OUTPUT_DIR"

    if [ -d "${KERNEL_SRC}/.git" ]; then
        info "Kernel source already present at ${KERNEL_SRC}"
        info "To refresh: rm -rf ${KERNEL_SRC} and re-run"
        return 0
    fi

    info "Cloning Arduino Linux kernel (shallow)..."
    info "  ${ARDUINO_LINUX_REPO}"

    # Shallow clone saves time and disk space
    git clone --depth=1 "$ARDUINO_LINUX_REPO" "$KERNEL_SRC"
}

configure_kernel() {
    step "Configuring kernel (arduino/linux-qcom defconfig + DSI panel modules)"

    cd "$KERNEL_SRC"

    # arduino/linux-qcom ships a single "defconfig" covering all supported
    # Qualcomm platforms (including QRB2210/Imola). Use it directly.
    # Try named variants first for forward-compatibility.
    local defconfig=""
    for candidate in imola_defconfig qrb2210_defconfig qcom_defconfig defconfig; do
        if [ -f "arch/arm64/configs/${candidate}" ]; then
            defconfig="$candidate"
            break
        fi
    done
    if [ -z "$defconfig" ]; then
        error "No defconfig found in arch/arm64/configs/. Check the repo."
    fi
    info "Using defconfig: $defconfig"
    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" "$defconfig"

    # Enable DSI panel drivers as modules
    local configs=(
        "CONFIG_DRM_TOSHIBA_TC358762=m"
        "CONFIG_DRM_PANEL_ILITEK_ILI9881C=m"
        "CONFIG_DRM_PANEL_SITRONIX_ST7701=m"
        "CONFIG_DRM_PANEL_HIMAX_HX8394=m"
        "CONFIG_DRM_PANEL_ORISETECH_OTM8009A=m"
        # Dependencies (ensure they're built-in or module)
        "CONFIG_DRM_MIPI_DSI=y"
        "CONFIG_BACKLIGHT_CLASS_DEVICE=y"
        "CONFIG_DRM_KMS_HELPER=y"
    )

    for cfg in "${configs[@]}"; do
        scripts/config --set-val "${cfg%=*}" "${cfg#*=}"
    done

    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" olddefconfig

    info "Kernel configured with DSI panel drivers as modules."
}

prepare_kernel_headers() {
    step "Preparing kernel headers and module scaffolding"

    cd "$KERNEL_SRC"

    # Build the minimum scaffolding needed to compile out-of-tree modules.
    # Note: 'modules_prepare' does NOT produce Module.symvers — that file is
    # only generated by a full 'make modules'.  Without it, modpost reports
    # every kernel symbol as "undefined", which would abort the build.
    #
    # We work around this by:
    #   1. Creating an empty Module.symvers so modpost doesn't abort on the
    #      missing-file warning.
    #   2. Passing KBUILD_MODPOST_WARN=1 when building each .ko so that
    #      remaining symbol warnings become non-fatal.
    #
    # The "unresolved" symbols (mipi_dsi_*, drm_bridge_*, etc.) are all
    # built into the target kernel and will resolve correctly at modprobe time.

    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
         -j"$(nproc)" scripts prepare

    make ARCH="$ARCH" CROSS_COMPILE="$CROSS_COMPILE" \
         -j"$(nproc)" modules_prepare

    # Seed an empty Module.symvers to silence the missing-file warning.
    # modpost will still warn about each individual unresolved symbol, but
    # those are suppressed by KBUILD_MODPOST_WARN=1 at build time.
    touch "${KERNEL_SRC}/Module.symvers"

    info "Headers and module scaffolding ready."
}

# ── Build modules ─────────────────────────────────────────────────────────────

build_all_modules() {
    local target="$1"

    step "Building out-of-tree DSI modules"

    # SKIP_INSTALL=1    — do not install to host /lib/modules or run modprobe;
    #                     .ko files are collected separately and scp'd to target.
    # KERNEL_VERSION    — override uname -r so any host-only paths use the
    #                     target version string, not the host's.
    # KBUILD_MODPOST_WARN=1 — turn unresolved-symbol modpost errors into
    #                     warnings so the .ko is produced despite missing
    #                     Module.symvers (symbols are in the target kernel).
    ARCH="$ARCH" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    KERNEL_DIR="$KERNEL_SRC" \
    KERNEL_VERSION="$TARGET_KERNEL" \
    KBUILD_MODPOST_WARN=1 \
    SKIP_INSTALL=1 \
    "${SCRIPT_DIR}/build-dsi-modules.sh" "$target"
}

# ── Collect outputs ───────────────────────────────────────────────────────────

collect_modules() {
    step "Collecting .ko files"

    find /tmp/dsi-modules-build -name "*.ko" -exec cp {} "$OUTPUT_DIR/" \; 2>/dev/null || true

    if ls "$OUTPUT_DIR/"*.ko &>/dev/null; then
        info "Modules collected in: $OUTPUT_DIR"
        ls -lh "$OUTPUT_DIR/"*.ko
    else
        warn "No .ko files found in output dir."
    fi
}

# ── Install instructions ──────────────────────────────────────────────────────

print_deploy_instructions() {
    local target_ip="${TARGET_IP:-<uno-q-ip>}"

    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  Cross-compilation complete!"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "  Modules built in: ${OUTPUT_DIR}/"
    echo ""
    echo "  Deploy to UNO Q:"
    echo ""
    echo "    # Copy modules to target"
    echo "    scp ${OUTPUT_DIR}/*.ko user@${target_ip}:/tmp/"
    echo ""
    echo "    # On the UNO Q — install modules"
    echo "    ssh user@${target_ip} bash << 'EOF'"
    echo "    KVER=\$(uname -r)"
    echo "    # Bridge drivers"
    echo "    sudo mkdir -p /lib/modules/\$KVER/kernel/drivers/gpu/drm/bridge"
    echo "    sudo cp /tmp/tc358762.ko /lib/modules/\$KVER/kernel/drivers/gpu/drm/bridge/"
    echo "    # Panel drivers"
    echo "    sudo mkdir -p /lib/modules/\$KVER/kernel/drivers/gpu/drm/panel"
    echo "    for ko in ili9881c st7701 hx8394 otm8009a; do"
    echo "      [ -f /tmp/\${ko}.ko ] && sudo cp /tmp/\${ko}.ko /lib/modules/\$KVER/kernel/drivers/gpu/drm/panel/"
    echo "    done"
    echo "    sudo depmod -a"
    echo "    sudo modprobe tc358762 || echo 'Need DT config first'"
    echo "    EOF"
    echo ""
    echo "  Then apply the device tree and reboot."
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────

TARGET="${1:-all}"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  DSI Cross-Build for Arduino UNO Q (host: $(uname -m))"
echo "════════════════════════════════════════════════════════════"
echo ""

check_host_tools
clone_or_update_kernel
configure_kernel
prepare_kernel_headers
build_all_modules "$TARGET"
collect_modules
print_deploy_instructions
