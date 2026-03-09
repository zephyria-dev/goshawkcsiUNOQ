#!/bin/bash
#
# Build a patched qcom-camss.ko that skips absent sensors
#
# The stock CAMSS driver waits for ALL sensors declared in the device tree
# to bind before registering the media device.  If any camera connector is
# unpopulated, the entire camera subsystem is blocked.
#
# This script patches camss.c to probe the I2C bus before adding a sensor
# to the v4l2 async notifier.  Absent sensors are silently skipped.
#
# Usage (on-device):
#   ./build-camss-patched.sh [KERNEL_SRC_DIR]
#
# Usage (cross-compile):
#   ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
#     ./build-camss-patched.sh /tmp/dsi-modules-cross/linux-qcom
#
# After cross-building, copy qcom-camss.ko to the board and install:
#   scp /tmp/camss-patched/qcom-camss.ko user@uno-q:/tmp/
#   ssh user@uno-q 'KVER=$(uname -r); \
#     sudo cp /lib/modules/$KVER/kernel/drivers/media/platform/qcom/camss/qcom-camss.ko{,.orig}; \
#     sudo cp /tmp/qcom-camss.ko /lib/modules/$KVER/kernel/drivers/media/platform/qcom/camss/; \
#     sudo depmod -a && sudo reboot'
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Kernel source — same one used by build-dsi-ondevice.sh / cross-build-dsi-modules.sh
KERNEL_SRC="${1:-${KERNEL_SRC_DIR:-/opt/arduino-linux-qcom}}"
CAMSS_SRC="${KERNEL_SRC}/drivers/media/platform/qcom/camss"
CAMSS_C="${CAMSS_SRC}/camss.c"

ARCH="${ARCH:-arm64}"
CROSS_COMPILE="${CROSS_COMPILE:-}"
WORK_DIR="/tmp/camss-patched"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  CAMSS Optional-Sensor Patch Builder"
echo "════════════════════════════════════════════════════════════"
echo ""

# ── Validate ─────────────────────────────────────────────────────────────

[ -f "$CAMSS_C" ] || error "CAMSS source not found: ${CAMSS_C}\n  Set KERNEL_SRC_DIR or pass the path as argument."
[ -f "${KERNEL_SRC}/Makefile" ] || error "Kernel source not at ${KERNEL_SRC}."

# ── Patch camss.c ────────────────────────────────────────────────────────

step "Patching camss.c"

if grep -q 'camss_sensor_is_present' "$CAMSS_C"; then
    info "Already patched — skipping."
else
    # Back up original
    cp "$CAMSS_C" "${CAMSS_C}.orig"
    info "Backed up ${CAMSS_C} → ${CAMSS_C}.orig"

    # --- 1. Add #include <linux/i2c.h> ---
    sed -i '/#include <linux\/interconnect.h>/a #include <linux/i2c.h>' "$CAMSS_C"

    # --- 2. Insert camss_sensor_is_present() before camss_of_parse_ports() ---
    # Create a temporary file with the function
    TMPFUNC=$(mktemp)
    cat > "$TMPFUNC" << 'ENDFUNC'
/*
 * camss_sensor_is_present - Check if a sensor responds on its I2C bus
 * @dev:         CAMSS device (for logging)
 * @sensor_node: DT node of the sensor (e.g. sensor@10)
 *
 * Probes the sensor I2C address to check physical presence.  If the I2C
 * adapter is not yet available (e.g. CCI not probed), returns true to
 * preserve the original behavior.
 *
 * Return: true  if sensor answered or detection was not possible
 *         false if bus was accessible and no device answered
 */
static bool camss_sensor_is_present(struct device *dev,
				    struct device_node *sensor_node)
{
	struct device_node *bus_node;
	struct i2c_adapter *adap;
	u32 reg;
	union i2c_smbus_data dummy;
	int ret;

	if (of_property_read_u32(sensor_node, "reg", &reg))
		return true;

	bus_node = of_get_parent(sensor_node);
	if (!bus_node)
		return true;

	adap = of_find_i2c_adapter_by_node(bus_node);
	of_node_put(bus_node);
	if (!adap)
		return true;

	ret = i2c_smbus_xfer(adap, reg, 0, I2C_SMBUS_READ, 0,
			     I2C_SMBUS_BYTE, &dummy);
	put_device(&adap->dev);

	if (ret < 0) {
		dev_info(dev,
			 "sensor %pOFn @0x%02x not detected (err %d), skipping\n",
			 sensor_node, reg, ret);
		return false;
	}

	dev_info(dev, "sensor %pOFn @0x%02x detected\n", sensor_node, reg);
	return true;
}

ENDFUNC

    # Find the "camss_of_parse_ports" function comment and insert before it
    PARSE_LINE=$(grep -n 'camss_of_parse_ports - Parse ports node' "$CAMSS_C" | head -1 | cut -d: -f1)
    if [ -z "$PARSE_LINE" ]; then
        rm "$TMPFUNC"
        error "Cannot find camss_of_parse_ports in camss.c"
    fi
    # The comment starts with "/*" two lines above
    INSERT_LINE=$((PARSE_LINE - 2))

    # Split file and reassemble with the function inserted
    head -n "$INSERT_LINE" "$CAMSS_C" > "${CAMSS_C}.tmp"
    cat "$TMPFUNC" >> "${CAMSS_C}.tmp"
    tail -n "+$((INSERT_LINE + 1))" "$CAMSS_C" >> "${CAMSS_C}.tmp"
    mv "${CAMSS_C}.tmp" "$CAMSS_C"
    rm "$TMPFUNC"
    info "Inserted camss_sensor_is_present()"

    # --- 3. Insert the check in camss_of_parse_ports() ---
    # We insert the check after the "Cannot get remote parent" error block,
    # right before the v4l2_async_nf_add_fwnode() call.
    TMPCHECK=$(mktemp)
    cat > "$TMPCHECK" << 'ENDCHECK'

		/* Skip sensors that are disabled or physically absent */
		if (!of_device_is_available(remote) ||
		    !camss_sensor_is_present(dev, remote)) {
			of_node_put(remote);
			continue;
		}

ENDCHECK

    # Find the v4l2_async_nf_add_fwnode line inside camss_of_parse_ports
    ADD_LINE=$(grep -n 'csd = v4l2_async_nf_add_fwnode(&camss->notifier,' "$CAMSS_C" | head -1 | cut -d: -f1)
    if [ -z "$ADD_LINE" ]; then
        rm "$TMPCHECK"
        error "Cannot find v4l2_async_nf_add_fwnode call in camss.c"
    fi

    head -n "$((ADD_LINE - 1))" "$CAMSS_C" > "${CAMSS_C}.tmp"
    cat "$TMPCHECK" >> "${CAMSS_C}.tmp"
    tail -n "+${ADD_LINE}" "$CAMSS_C" >> "${CAMSS_C}.tmp"
    mv "${CAMSS_C}.tmp" "$CAMSS_C"
    rm "$TMPCHECK"
    info "Inserted sensor check in camss_of_parse_ports()"
fi

# ── Build ────────────────────────────────────────────────────────────────

step "Building qcom-camss.ko"

mkdir -p "$WORK_DIR"

MAKE_ARGS=(
    ARCH="$ARCH"
    KBUILD_MODPOST_WARN=1
    -C "$KERNEL_SRC"
    M="drivers/media/platform/qcom/camss"
)
[ -n "$CROSS_COMPILE" ] && MAKE_ARGS+=(CROSS_COMPILE="$CROSS_COMPILE")

make "${MAKE_ARGS[@]}" clean 2>/dev/null || true
make "${MAKE_ARGS[@]}" -j"$(nproc)" modules

KO="${CAMSS_SRC}/qcom-camss.ko"
if [ ! -f "$KO" ]; then
    error "Build failed — qcom-camss.ko not produced."
fi

cp "$KO" "${WORK_DIR}/"
info "Built: ${WORK_DIR}/qcom-camss.ko  ($(du -sh "$KO" | cut -f1))"

# ── Install (on-device only) ─────────────────────────────────────────────

if [ -z "$CROSS_COMPILE" ] && [ "$(uname -m)" = "aarch64" ]; then
    KVER="$(uname -r)"
    DEST="/lib/modules/${KVER}/kernel/drivers/media/platform/qcom/camss"

    step "Installing qcom-camss.ko → ${DEST}"
    sudo mkdir -p "$DEST"

    if [ -f "${DEST}/qcom-camss.ko" ] && \
       [ ! -f "${DEST}/qcom-camss.ko.orig" ]; then
        sudo cp "${DEST}/qcom-camss.ko" "${DEST}/qcom-camss.ko.orig"
        info "Backed up original → qcom-camss.ko.orig"
    fi

    sudo cp "$KO" "${DEST}/"
    sudo depmod -a
    info "Installed."

    step "Reloading qcom-camss"
    if lsmod | grep -q '^qcom_camss'; then
        if sudo modprobe -r qcom-camss 2>/dev/null; then
            info "Unloaded old qcom-camss"
        else
            warn "Cannot unload qcom-camss (in use). Reboot to activate."
        fi
    fi
    sudo modprobe qcom-camss 2>/dev/null && info "Loaded patched qcom-camss" || \
        warn "modprobe failed — reboot to activate."

    echo ""
    echo "  Verify:"
    echo "    ls /dev/media*"
    echo "    dmesg | grep -i 'sensor.*detected\\|sensor.*skipping\\|camss'"
    echo ""
else
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  Cross-build complete"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "  Module: ${WORK_DIR}/qcom-camss.ko"
    echo ""
    echo "  Deploy to UNO Q:"
    echo "    scp ${WORK_DIR}/qcom-camss.ko user@<uno-q>:/tmp/"
    echo ""
    echo "    # On UNO Q:"
    echo "    KVER=\$(uname -r)"
    echo "    DEST=/lib/modules/\$KVER/kernel/drivers/media/platform/qcom/camss"
    echo "    sudo cp \$DEST/qcom-camss.ko \$DEST/qcom-camss.ko.orig"
    echo "    sudo cp /tmp/qcom-camss.ko \$DEST/"
    echo "    sudo depmod -a && sudo reboot"
    echo ""
fi
