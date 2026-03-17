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
# The resulting image includes all packages and services
# pre-installed — clones don't need internet on first boot.

set -euo pipefail

# Safety check: refuse to run on non-Pi hardware (clears history + removes node config)
if ! grep -qi "raspberry pi\|BCM2" /proc/cpuinfo 2>/dev/null; then
    echo -e "\033[0;31mERROR: This doesn't look like a Raspberry Pi!\033[0m"
    echo "This script clears history and removes node config — don't run on your laptop."
    read -rp "Continue anyway? [y/N] " confirm
    [[ ! "${confirm:-}" =~ ^[Yy]$ ]] && { echo "Aborted."; exit 1; }
fi

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$NIGHTWATCH_DIR/scripts/common.sh"

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

# ---- Step 0: Update project to latest ----

echo "[0/7] Updating project to latest version..."
if [ -d "$NIGHTWATCH_DIR/.git" ]; then
    timeout 30 git -C "$NIGHTWATCH_DIR" pull --ff-only 2>/dev/null && echo "[+] Updated from git" || echo "[+] Git pull skipped (no internet or not a repo)"
else
    echo "[+] Not a git repo — using existing files"
fi

# ---- Step 1: Stop services ----

echo "[1/7] Stopping services..."
systemctl stop nightwatch-app.service 2>/dev/null || true
systemctl stop nightwatch-discovery.service 2>/dev/null || true
systemctl stop nightwatch-mesh.service 2>/dev/null || true
echo "[+] Services stopped"

# ---- Step 2: Verify irc-bridge binary ----

echo ""
echo "[2/7] Checking irc-bridge binary..."
if [ -x "$NIGHTWATCH_DIR/irc-bridge-go/irc-bridge" ]; then
    echo "[+] irc-bridge binary present ($(ls -lh "$NIGHTWATCH_DIR/irc-bridge-go/irc-bridge" | awk '{print $5}'))"
else
    echo -e "${RED}[!] irc-bridge binary missing — cross-compile on laptop first: make build-bridge${NC}"
fi

# ---- Step 3: Verify native services ----

echo ""
echo "[3/7] Checking native service installations..."
for pkg in ngircd nginx; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        echo "  [+] $pkg installed"
    else
        echo -e "  ${RED}[!] $pkg not installed${NC}"
    fi
done

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

# Save secrets (passwords, Tailscale key) so clones inherit them
# These are NOT in .env.example (which is public/git-tracked)
SECRETS_FILE="$NIGHTWATCH_DIR/.secrets"
if [ -f "$NIGHTWATCH_DIR/.env" ]; then
    echo "# Nightwatch secrets — preserved from golden image" > "$SECRETS_FILE"
    echo "# These get injected into .env by nodeconfig.sh on boot" >> "$SECRETS_FILE"
    # Strip surrounding quotes from values so nodeconfig's set_env_value
    # doesn't double-quote them (e.g. KEY='$val' → KEY=$val in .secrets)
    grep -E '^(ROUTER_PASSWORD|IRC_LINK_PASSWORD|TAILSCALE_AUTH_KEY)=' "$NIGHTWATCH_DIR/.env" \
        | sed "s/='\(.*\)'$/=\1/; s/=\"\(.*\)\"$/=\1/" \
        >> "$SECRETS_FILE" 2>/dev/null || true
    chmod 600 "$SECRETS_FILE"
    echo "  Saved secrets to .secrets"
fi

# Remove .env (will be generated on first boot)
rm -f "$NIGHTWATCH_DIR/.env"
echo "  Removed .env"

# Remove saved node number (so clone does fresh dynamic assignment)
rm -f "$NIGHTWATCH_DIR/.node-number"
echo "  Removed .node-number"

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

install_systemd_services "$NIGHTWATCH_DIR"

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
# Regenerate immediately so SSH still works if we don't capture the image right away
# (clones will regenerate their own unique keys via sshd-keygen on first boot)
ssh-keygen -A >/dev/null 2>&1 || true
systemctl restart sshd 2>/dev/null || true

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
echo "     # Download PiShrink: https://github.com/Drewsif/PiShrink"
echo "     sudo bash pishrink.sh nightwatch.img"
echo ""
echo -e "  ${BOLD}5. Compress for Pi Imager (supports .img.xz natively):${NC}"
echo "     sudo xz -9 -T0 nightwatch.img"
echo "     # Creates nightwatch.img.xz (~60-70% smaller)"
echo ""
echo -e "  ${BOLD}6. Flash to other SD cards with Raspberry Pi Imager:${NC}"
echo "     → Choose OS → Use custom → select nightwatch.img.xz"
echo "     → Choose storage → Flash"
echo "     No configuration needed — each Pi auto-assigns its node number."
echo ""
echo -e "  ${YELLOW}Note: This golden image has all packages and services pre-installed.${NC}"
echo -e "  ${YELLOW}Clones do NOT need internet on first boot — they just auto-configure.${NC}"
echo ""
echo "  That's it. Flash → boot → auto-configures → joins the mesh."
echo ""
