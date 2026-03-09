#!/bin/bash
#
# Build TC358762 DSI-to-DPI Bridge Kernel Module for Arduino UNO Q
#
# This module is required for:
#   - Freenove 4.3" Touchscreen
#   - Official Raspberry Pi 7" Display
#   - WaveShare DSI displays using TC358762
#
# Run this script ON the Arduino UNO Q
#

set -e

echo "=============================================="
echo " TC358762 Kernel Module Builder for UNO Q"
echo "=============================================="
echo ""

# Configuration
WORK_DIR="/tmp/tc358762-build"
KERNEL_VERSION=$(uname -r)
MODULE_NAME="tc358762"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    error "Do not run as root. Script will use sudo when needed."
fi

# Step 1: Check prerequisites
info "Checking prerequisites..."

if ! command -v make &>/dev/null; then
    warn "Installing build-essential..."
    sudo apt update
    sudo apt install -y build-essential bc flex bison
fi

# Step 2: Check for kernel headers
info "Checking for kernel headers..."

HEADERS_DIR="/lib/modules/${KERNEL_VERSION}/build"
if [ ! -d "$HEADERS_DIR" ]; then
    warn "Kernel headers not found at $HEADERS_DIR"
    echo ""
    echo "Attempting to install kernel headers..."

    if ! sudo apt install -y linux-headers-${KERNEL_VERSION} 2>/dev/null; then
        echo ""
        error "Kernel headers not available via apt.

You need to either:
  1. Build from Arduino's kernel source (see Method 2 in RPI-DISPLAY-COMPATIBILITY.md)
  2. Cross-compile on a host PC (faster, see Method 3)

The kernel headers package for ${KERNEL_VERSION} is not in the repository."
    fi
fi

info "Kernel headers found at $HEADERS_DIR"

# Step 3: Create work directory
info "Creating work directory..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Step 4: Download tc358762.c source
info "Downloading tc358762.c source..."

# Try arduino/linux-qcom first, fall back to upstream torvalds tree
ARDUINO_URL="https://raw.githubusercontent.com/arduino/linux-qcom/main/drivers/gpu/drm/bridge/tc358762.c"
UPSTREAM_URL="https://raw.githubusercontent.com/torvalds/linux/v6.16/drivers/gpu/drm/bridge/tc358762.c"

if curl -fsSL "$ARDUINO_URL" -o tc358762.c 2>/dev/null; then
    info "  Source fetched from arduino/linux-qcom"
elif curl -fsSL "$UPSTREAM_URL" -o tc358762.c; then
    info "  Source fetched from torvalds/linux v6.16 (fallback)"
else
    error "Failed to download tc358762.c from both arduino/linux-qcom and torvalds/linux"
fi

# Step 5: Create Kbuild file
info "Creating Kbuild file..."

cat > Kbuild << 'EOF'
# Kbuild file for tc358762 out-of-tree module
obj-m := tc358762.o
EOF

# Step 6: Create Makefile
cat > Makefile << 'EOF'
KERNEL_VERSION ?= $(shell uname -r)
KERNEL_DIR ?= /lib/modules/$(KERNEL_VERSION)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) clean

install:
	$(MAKE) -C $(KERNEL_DIR) M=$(PWD) modules_install
	depmod -a

.PHONY: all clean install
EOF

# Step 7: Build module
info "Building tc358762.ko module..."
echo ""

if ! make 2>&1; then
    echo ""
    error "Module build failed. Check error messages above.

Common issues:
  - Missing kernel headers: install linux-headers-${KERNEL_VERSION}
  - Kernel config mismatch: source must match running kernel
  - Missing dependencies: check for DRM_MIPI_DSI, DRM_KMS_HELPER"
fi

# Step 8: Check module was built
if [ ! -f "tc358762.ko" ]; then
    error "Module tc358762.ko was not created"
fi

info "Module built successfully!"
echo ""
ls -la tc358762.ko
echo ""

# Step 9: Install module
info "Installing module..."

INSTALL_DIR="/lib/modules/${KERNEL_VERSION}/kernel/drivers/gpu/drm/bridge"
sudo mkdir -p "$INSTALL_DIR"
sudo cp tc358762.ko "$INSTALL_DIR/"
sudo depmod -a

# Step 10: Load module
info "Loading module..."

if sudo modprobe tc358762; then
    info "Module loaded successfully!"
else
    warn "Module load failed - may need device tree configuration first"
fi

# Step 11: Verify
echo ""
echo "=============================================="
echo " Build Complete!"
echo "=============================================="
echo ""
echo "Module installed to: $INSTALL_DIR/tc358762.ko"
echo ""
echo "To verify:"
echo "  lsmod | grep tc358762"
echo "  modinfo tc358762"
echo ""
echo "Next steps:"
echo "  1. Configure device tree for your display (see DSI-DISPLAY-GUIDE.md)"
echo "  2. Reboot to apply device tree changes"
echo "  3. Check dmesg for display initialization"
echo ""
echo "Build files preserved in: $WORK_DIR"
echo ""
