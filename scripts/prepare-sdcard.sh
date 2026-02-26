#!/bin/bash
# Nightwatch — Prepare an SD card
#
# Run this on your laptop AFTER flashing Raspberry Pi OS Lite with Pi Imager.
# Pi Imager settings:
#   - OS: Raspberry Pi OS Lite (64-bit recommended)
#   - Set hostname (e.g. nightwatch)
#   - Enable SSH (password or key)
#   - Set username/password
#   - Set WiFi (temporary — for first boot internet access to install packages)
#
# Node number is assigned dynamically on first boot by scanning the mesh network.
#
# Usage:
#   ./scripts/prepare-sdcard.sh <sdcard_rootfs_path> [options]
#
# Examples:
#   ./scripts/prepare-sdcard.sh /run/media/$USER/rootfs
#   ./scripts/prepare-sdcard.sh /Volumes/rootfs --gateway
#   ./scripts/prepare-sdcard.sh /media/user/rootfs --yes
#
# What it does:
#   1. Copies the entire project to /opt/nightwatch/ on the SD card
#   2. Saves secrets to .secrets (nodeconfig generates .env on first boot)
#   3. Writes /etc/nightwatch.conf on the SD card
#   4. Installs the firstboot service (runs on first boot — installs everything)
#
# Secrets:
#   The script prompts for passwords and Tailscale auth key, then bakes them
#   into .secrets on the SD card. You can also set them via environment:
#     ROUTER_PASSWORD=xxx IRC_LINK_PASSWORD=yyy TAILSCALE_AUTH_KEY=zzz ./scripts/prepare-sdcard.sh /path/to/rootfs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- Usage ----

usage() {
    echo "Usage: $0 <sdcard_rootfs_path> [options]"
    echo ""
    echo "  sdcard_path:  Path to the SD card's rootfs partition (required)"
    echo ""
    echo "Options:"
    echo "  --gateway     Mark this node as the internet gateway"
    echo "  --yes         Skip confirmation prompts"
    echo ""
    echo "Examples:"
    echo "  $0 /run/media/\$USER/rootfs"
    echo "  $0 /Volumes/rootfs --gateway"
    echo ""
    echo "Node number is assigned dynamically on first boot by scanning the mesh."
    echo ""
    echo "Environment variables (optional — skips password prompts):"
    echo "  ROUTER_PASSWORD     GL.iNet router admin password"
    echo "  IRC_LINK_PASSWORD   IRC federation password (same on all nodes)"
    echo "  TAILSCALE_AUTH_KEY  Tailscale pre-auth key (from admin console)"
    exit 1
}

GATEWAY_MODE=false
SD_ROOT=""
AUTO_YES=false

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --gateway) GATEWAY_MODE=true ;;
        --yes|-y)  AUTO_YES=true ;;
        --help|-h) usage ;;
        *)         SD_ROOT="$1" ;;
    esac
    shift
done

# ---- Validate SD card path ----

if [ -z "$SD_ROOT" ]; then
    echo -e "${RED}Error: SD card rootfs path is required${NC}"
    usage
fi

# Validate SD card root
if [ ! -d "$SD_ROOT/etc" ] || [ ! -d "$SD_ROOT/opt" ]; then
    echo -e "${RED}Error: $SD_ROOT does not look like a Linux rootfs${NC}"
    echo "Expected to find $SD_ROOT/etc and $SD_ROOT/opt"
    exit 1
fi

if [ ! -d "$SD_ROOT/etc/systemd/system" ]; then
    echo -e "${RED}Error: $SD_ROOT does not have systemd (not a Pi OS image?)${NC}"
    exit 1
fi

# ---- Load base config ----

ENV_TEMPLATE="$PROJECT_DIR/.env.example"
if [ ! -f "$ENV_TEMPLATE" ]; then
    echo -e "${RED}Error: .env.example not found in project${NC}"
    exit 1
fi

set -o allexport
# shellcheck source=/dev/null
source "$ENV_TEMPLATE"
set +o allexport


# ---- Prompt for secrets ----

# Router password
if [ -z "${ROUTER_PASSWORD:-}" ] || [ "$ROUTER_PASSWORD" = "CHANGE_ME_BEFORE_DEPLOY" ]; then
    echo ""
    echo -e "${BOLD}Set passwords for this deployment:${NC}"
    echo -e "${YELLOW}(These are baked into the SD card — same values for all nodes)${NC}"
    echo ""
    read -rsp "  GL.iNet router admin password: " ROUTER_PASSWORD
    echo ""
fi

# IRC link password
if [ -z "${IRC_LINK_PASSWORD:-}" ] || [ "$IRC_LINK_PASSWORD" = "CHANGE_ME_BEFORE_DEPLOY" ]; then
    read -rsp "  IRC federation password (same on ALL nodes): " IRC_LINK_PASSWORD
    echo ""
fi

# Tailscale auth key
if [ -z "${TAILSCALE_AUTH_KEY:-}" ]; then
    echo ""
    echo -e "  ${CYAN}Tailscale auth key (optional — enables remote SSH access)${NC}"
    echo -e "  ${CYAN}Generate at: https://login.tailscale.com/admin/settings/keys${NC}"
    echo -e "  ${CYAN}Use a reusable key so multiple Pis can join.${NC}"
    read -rp "  Tailscale auth key (or press Enter to skip): " TAILSCALE_AUTH_KEY
fi

echo ""
echo -e "${BOLD}${CYAN}======================================"
echo "  Nightwatch SD Card Preparation"
echo "======================================${NC}"
echo ""
echo "  Node:       (auto-assigned on first boot)"
echo "  Gateway:    $GATEWAY_MODE"
echo "  Tailscale:  $([ -n "${TAILSCALE_AUTH_KEY:-}" ] && echo 'yes (auth key set)' || echo 'no')"
echo "  SD card:    $SD_ROOT"
echo ""

# Confirm
if [ "$AUTO_YES" != true ]; then
    echo -e "${YELLOW}This will write to $SD_ROOT/opt/nightwatch/${NC}"
    read -rp "Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo ""

# ---- Step 1: Copy project ----

echo "[1/5] Copying project to SD card..."
DEST="$SD_ROOT/opt/nightwatch"
sudo mkdir -p "$DEST"

# Copy everything except .git, .env, and generated files
sudo rsync -a --delete \
    --exclude='.git' \
    --exclude='.env' \
    --exclude='ngircd/ngircd.conf' \
    --exclude='dnsmasq/dnsmasq.conf' \
    --exclude='*.log' \
    --exclude='.DS_Store' \
    --exclude='node_modules' \
    --exclude='irc-bridge-go/irc-bridge' \
    --exclude='.firstboot-done' \
    "$PROJECT_DIR/" "$DEST/"

echo "[+] Project copied to $DEST"

# ---- Step 2: Save secrets ----

echo "[2/5] Saving secrets (nodeconfig generates .env on first boot)..."

SECRETS_DEST="$DEST/.secrets"
sudo bash -c "cat > '$SECRETS_DEST'" << SECRETSEOF
# Nightwatch secrets — baked by prepare-sdcard.sh
# nodeconfig.sh injects these into .env on first boot
ROUTER_PASSWORD='${ROUTER_PASSWORD}'
IRC_LINK_PASSWORD='${IRC_LINK_PASSWORD}'
TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY:-}
SECRETSEOF
sudo chmod 600 "$SECRETS_DEST"

if [ "$GATEWAY_MODE" = true ]; then
    echo "MESH_GATEWAY=true" | sudo tee -a "$SECRETS_DEST" > /dev/null
fi

# Remove any .env so nodeconfig generates a fresh one
sudo rm -f "$DEST/.env"

echo "[+] Secrets saved"
echo "    ROUTER_PASSWORD=***"
echo "    IRC_LINK_PASSWORD=***"
echo "    TAILSCALE_AUTH_KEY=$([ -n "${TAILSCALE_AUTH_KEY:-}" ] && echo '***' || echo '(empty)')"

# ---- Step 3: Write /etc/nightwatch.conf ----

echo "[3/5] Writing nightwatch.conf..."
echo "NIGHTWATCH_DIR=/opt/nightwatch" | sudo tee "$SD_ROOT/etc/nightwatch.conf" > /dev/null
echo "[+] /etc/nightwatch.conf written"

# ---- Step 4: Install firstboot service ----

echo "[4/5] Installing firstboot service..."
sudo chmod +x "$DEST/scripts/firstboot.sh"
sudo chmod +x "$DEST/scripts/mesh-fix.sh"
sudo chmod +x "$DEST/scripts/setup-rpi.sh"
sudo chmod +x "$DEST/scripts/setup-distributed-irc.sh"
sudo chmod +x "$DEST/scripts/nodeconfig.sh"
sudo chmod +x "$DEST/scripts/node-discovery.sh"

# Copy systemd service
sudo cp "$DEST/scripts/nightwatch-firstboot.service" \
    "$SD_ROOT/etc/systemd/system/nightwatch-firstboot.service"

# Enable it (create the symlink manually since systemctl won't work on a mounted FS)
sudo mkdir -p "$SD_ROOT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/nightwatch-firstboot.service \
    "$SD_ROOT/etc/systemd/system/multi-user.target.wants/nightwatch-firstboot.service"

echo "[+] Firstboot service installed and enabled"

# ---- Step 5: Verify ----

echo "[5/5] Verifying..."

ERRORS=0
for f in .env.example .secrets scripts/firstboot.sh scripts/mesh-fix.sh scripts/nodeconfig.sh scripts/node-discovery.sh scripts/setup-distributed-irc.sh docker-compose.yml irc-bridge-go/Dockerfile html/index.html; do
    if [ ! -f "$DEST/$f" ]; then
        echo -e "  ${RED}[MISS] $f${NC}"
        ((ERRORS++))
    fi
done

if [ ! -f "$SD_ROOT/etc/nightwatch.conf" ]; then
    echo -e "  ${RED}[MISS] /etc/nightwatch.conf${NC}"
    ((ERRORS++))
fi

if [ ! -L "$SD_ROOT/etc/systemd/system/multi-user.target.wants/nightwatch-firstboot.service" ]; then
    echo -e "  ${RED}[MISS] firstboot service symlink${NC}"
    ((ERRORS++))
fi

if [ "$ERRORS" -gt 0 ]; then
    echo -e "${RED}Warning: $ERRORS missing files — check the output above${NC}"
else
    echo -e "  ${GREEN}All files present${NC}"
fi

# ---- Done ----

echo ""
echo -e "${GREEN}${BOLD}======================================"
echo "  SD Card Ready!"
echo "======================================${NC}"
echo ""
echo "  Node:       (auto-assigned on first boot)"
echo "  Gateway:    $GATEWAY_MODE"
echo "  Tailscale:  $([ -n "${TAILSCALE_AUTH_KEY:-}" ] && echo 'yes' || echo 'no')"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "  1. Eject the SD card safely"
echo "  2. Insert into the Raspberry Pi"
echo "  3. Power on — first boot setup runs automatically (~10-15 min)"
echo "     It needs internet (WiFi configured in Pi Imager, or Ethernet)"
echo ""
echo -e "  ${BOLD}Monitor progress (after Pi boots):${NC}"
echo "     ssh into the Pi, then:"
echo "     journalctl -f -u nightwatch-firstboot"
echo "     tail -f /var/log/nightwatch-firstboot.log"
echo ""
echo "  After first boot completes, the Pi will:"
echo "  - Start the mesh network automatically on every boot"
echo "  - Start Docker services (IRC, bridge, web UI)"
echo "  - Broadcast WiFi hotspot '${WIFI_SSID:-Nightwatch}'"
if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
echo "  - Be accessible remotely via Tailscale"
fi
echo ""
