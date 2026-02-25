#!/bin/bash
# Nightwatch — Build a reusable Pi image from a running, configured Pi
#
# Run this ON the Pi after a full manual setup (make install works, mesh works).
# It prepares the system for cloning: removes node-specific config so each
# clone can auto-configure on first boot based on hostname.
#
# Workflow:
#   1. Setup one Pi fully (setup-rpi.sh, make start, verify everything works)
#   2. Run this script ON that Pi
#   3. Shut down the Pi, pull the SD card
#   4. On your laptop: copy the SD card to an .img file
#   5. (Optional) Shrink with PiShrink, compress to .img.xz
#   6. Flash that image to other SD cards with Pi Imager (Use custom image)
#   7. Each Pi auto-configures based on hostname set in Pi Imager
#
# Usage: sudo ./scripts/build-image.sh
#
# The resulting image includes all packages, Docker images, and services
# pre-installed — clones don't need internet on first boot.

set -euo pipefail

# Read project path from /etc/nightwatch.conf (written by setup-rpi.sh)
if [ -f /etc/nightwatch.conf ]; then
    # shellcheck source=/dev/null
    source /etc/nightwatch.conf
fi
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-/opt/nightwatch}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: must run as root (sudo)${NC}"
    exit 1
fi

echo ""
echo -e "${BOLD}======================================"
echo "  Nightwatch — Image Builder"
echo "======================================${NC}"
echo ""
echo "This prepares the current Pi for cloning."
echo "After this, shutdown -> capture SD card -> flash to other cards."
echo ""

# Verify nightwatch is installed
if [ ! -d "$NIGHTWATCH_DIR" ]; then
    echo -e "${RED}Error: $NIGHTWATCH_DIR not found. Run setup first.${NC}"
    exit 1
fi

cd "$NIGHTWATCH_DIR"

# ---- Step 1: Stop services ----

echo "[1/7] Stopping services..."
docker compose --env-file .env down 2>/dev/null || true
systemctl stop nightwatch-discovery.service 2>/dev/null || true
systemctl stop nightwatch-mesh.service 2>/dev/null || true
echo "[+] Services stopped"

# ---- Step 2: Pre-build Docker images ----

echo ""
echo "[2/7] Pre-building Docker images (so clones don't need internet)..."
docker compose --env-file .env build
echo "[+] Docker images built and cached"

# ---- Step 3: Pre-pull base images ----

echo ""
echo "[3/7] Pre-pulling base images..."
docker pull linuxserver/ngircd:latest
docker pull nginx:alpine
echo "[+] Base images cached"

# ---- Step 4: Logout Tailscale ----

echo ""
echo "[4/7] Cleaning Tailscale state..."
if command -v tailscale >/dev/null 2>&1; then
    # Logout so the clone doesn't conflict with this node's identity
    tailscale logout 2>/dev/null || true
    systemctl stop tailscaled 2>/dev/null || true
    # Clear Tailscale state (each clone will re-auth with the auth key)
    rm -rf /var/lib/tailscale/tailscaled.state 2>/dev/null || true
    echo "[+] Tailscale logged out and state cleared"
    echo "    (Clones will re-authenticate using TAILSCALE_AUTH_KEY from .env)"
else
    echo "[+] Tailscale not installed — skipping"
fi

# ---- Step 5: Remove node-specific config ----

echo ""
echo "[5/7] Removing node-specific configuration..."

# Remove .env (will be generated on first boot from hostname)
rm -f "$NIGHTWATCH_DIR/.env"
echo "  Removed .env"

# Remove generated ngircd config
rm -f "$NIGHTWATCH_DIR/ngircd/ngircd.conf"
echo "  Removed ngircd.conf"

# Remove generated dnsmasq config
rm -f "$NIGHTWATCH_DIR/dnsmasq/dnsmasq.conf"
echo "  Removed dnsmasq.conf"

# Remove firstboot stamp if present
rm -f "$NIGHTWATCH_DIR/.firstboot-done"

# Remove any logs
rm -f /var/log/nightwatch-firstboot.log
echo "  Cleaned logs"

# ---- Step 6: Install nodeconfig service ----

echo ""
echo "[6/7] Installing nodeconfig service (auto-configures on boot)..."

# Ensure scripts are executable
chmod +x "$NIGHTWATCH_DIR/scripts/nodeconfig.sh"
chmod +x "$NIGHTWATCH_DIR/scripts/mesh-fix.sh"
chmod +x "$NIGHTWATCH_DIR/scripts/setup-distributed-irc.sh"
chmod +x "$NIGHTWATCH_DIR/scripts/node-discovery.sh"

# Install the nodeconfig service
cp "$NIGHTWATCH_DIR/scripts/nightwatch-nodeconfig.service" \
    /etc/systemd/system/nightwatch-nodeconfig.service
systemctl daemon-reload
systemctl enable nightwatch-nodeconfig.service
echo "[+] Nodeconfig service enabled"

# Make sure mesh service is enabled
cp "$NIGHTWATCH_DIR/scripts/nightwatch-mesh.service" \
    /etc/systemd/system/nightwatch-mesh.service
systemctl enable nightwatch-mesh.service
echo "[+] Mesh service enabled"

# Install discovery service
cp "$NIGHTWATCH_DIR/scripts/nightwatch-discovery.service" \
    /etc/systemd/system/nightwatch-discovery.service
systemctl enable nightwatch-discovery.service
echo "[+] Discovery service enabled"

# Install Docker autostart service
cp "$NIGHTWATCH_DIR/scripts/nightwatch-docker.service" \
    /etc/systemd/system/nightwatch-docker.service
systemctl enable nightwatch-docker.service
echo "[+] Docker autostart service enabled"

# ---- Step 7: Clean up system ----

echo ""
echo "[7/7] Cleaning up system for image capture..."

# Clear bash history
: > ~/.bash_history
history -c 2>/dev/null || true

# Clear apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*

# Clear temp files
rm -rf /tmp/*
rm -rf /var/tmp/*

# Clear machine-id (will regenerate on boot — makes each clone unique)
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id

# Clear SSH host keys (will regenerate on boot — each clone gets unique keys)
rm -f /etc/ssh/ssh_host_*

# Clear journald logs
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-time=1s 2>/dev/null || true

echo "[+] System cleaned"

# ---- Done ----

echo ""
echo -e "${GREEN}${BOLD}======================================"
echo "  Image Ready for Capture!"
echo "======================================${NC}"
echo ""
echo "  Now do the following:"
echo ""
echo -e "  ${BOLD}1. Shut down this Pi:${NC}"
echo "     sudo shutdown -h now"
echo ""
echo -e "  ${BOLD}2. Pull the SD card and insert into your laptop${NC}"
echo ""
echo -e "  ${BOLD}3. Copy the SD card to an image file:${NC}"
echo ""
echo "     macOS:"
echo "       diskutil list                    # Find the SD card (e.g. /dev/disk4)"
echo "       sudo dd if=/dev/rdisk4 of=nightwatch.img bs=4m status=progress"
echo ""
echo "     Linux:"
echo "       lsblk                            # Find the SD card (e.g. /dev/sdb)"
echo "       sudo dd if=/dev/sdb of=nightwatch.img bs=4M status=progress"
echo ""
echo -e "  ${BOLD}4. (Recommended) Shrink the image:${NC}"
echo "     # Install PiShrink: https://github.com/Drewsif/PiShrink"
echo "     sudo pishrink.sh nightwatch.img"
echo ""
echo -e "  ${BOLD}5. Compress for Pi Imager (supports .img.xz natively):${NC}"
echo "     xz -9 -T0 nightwatch.img"
echo "     # Creates nightwatch.img.xz (~60-70% smaller)"
echo ""
echo -e "  ${BOLD}6. Flash to other SD cards:${NC}"
echo "     Open Pi Imager -> Choose OS -> Use custom -> select nightwatch.img.xz"
echo "     In settings, set ONLY:"
echo "       - Hostname: nightwatch-1 (or nightwatch-2, nightwatch-3, etc.)"
echo "       - Enable SSH"
echo "       - Username/password"
echo "       - WiFi (if the node needs internet, e.g. gateway)"
echo "     The node number is derived from the hostname automatically."
echo ""
echo -e "  ${YELLOW}Note: This golden image has all packages and Docker images pre-installed.${NC}"
echo -e "  ${YELLOW}Clones do NOT need internet on first boot — they just auto-configure.${NC}"
echo -e "  ${YELLOW}If you want Tailscale, add TAILSCALE_AUTH_KEY to .env.example before${NC}"
echo -e "  ${YELLOW}running build-image.sh, or use prepare-sdcard.sh instead.${NC}"
echo ""
echo "  That's it. Each Pi boots -> auto-configures -> joins the mesh."
echo ""
