#!/bin/bash
#
# Install the Zephyria Shield systemd service
#
# Copies zephyria-setup.sh and enables the service so all
# peripherals (display, audio, cameras) are configured at boot.
#
# Usage:
#   sudo ./install-service.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}Run as root: sudo $0${NC}"; exit 1; }

echo "Installing Zephyria Shield service..."

# Copy setup script
cp "$SCRIPT_DIR/zephyria-setup.sh" /usr/local/bin/zephyria-setup.sh
chmod +x /usr/local/bin/zephyria-setup.sh
echo -e "  ${GREEN}✓${NC}  /usr/local/bin/zephyria-setup.sh"

# Copy and enable systemd service
cp "$SCRIPT_DIR/zephyria-setup.service" /etc/systemd/system/zephyria-setup.service
systemctl daemon-reload
systemctl enable zephyria-setup.service
echo -e "  ${GREEN}✓${NC}  zephyria-setup.service enabled"

echo ""
echo "Done. The service will run at every boot."
echo ""
echo "  Manual commands:"
echo "    sudo zephyria-setup.sh setup    # Run now"
echo "    sudo zephyria-setup.sh status   # Check devices"
echo "    journalctl -u zephyria-setup    # View boot log"
echo "    sudo systemctl disable zephyria-setup  # Disable"
echo ""
