#!/bin/bash
# Nightwatch — Prepare an SD card for a specific node
#
# Run this on your laptop AFTER flashing Raspberry Pi OS Lite with Pi Imager.
# Pi Imager settings:
#   - OS: Raspberry Pi OS Lite (64-bit recommended)
#   - Set hostname (e.g. nightwatch-1)
#   - Enable SSH (password or key)
#   - Set username/password
#   - Set WiFi (temporary — for first boot internet access to install packages)
#
# Usage:
#   ./scripts/prepare-sdcard.sh <node_number> [sdcard_root]
#
# Examples:
#   ./scripts/prepare-sdcard.sh 1                    # Auto-detect SD card mount
#   ./scripts/prepare-sdcard.sh 2 /Volumes/rootfs    # macOS explicit path
#   ./scripts/prepare-sdcard.sh 3 /media/user/rootfs # Linux explicit path
#
# What it does:
#   1. Copies the entire project to /opt/nightwatch/ on the SD card
#   2. Generates a node-specific .env file
#   3. Installs the firstboot service (runs on first boot)

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
    echo "Usage: $0 <node_number> [sdcard_rootfs_path]"
    echo ""
    echo "  node_number:  Pi number (1, 2, 3, ...) — must match .env.example config"
    echo "  sdcard_path:  Path to the SD card's rootfs partition (auto-detected if omitted)"
    echo ""
    echo "Examples:"
    echo "  $0 1                          # Auto-detect SD card"
    echo "  $0 2 /Volumes/rootfs          # macOS"
    echo "  $0 3 /media/\$USER/rootfs      # Linux"
    echo "  $0 1 --gateway                # Mark node as gateway (internet sharing)"
    exit 1
}

if [ $# -lt 1 ]; then
    usage
fi

NODE_NUM="$1"
GATEWAY_MODE=false
SD_ROOT=""

# Parse args
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --gateway) GATEWAY_MODE=true ;;
        *)         SD_ROOT="$1" ;;
    esac
    shift
done

# Validate node number
if ! [[ "$NODE_NUM" =~ ^[0-9]+$ ]] || [ "$NODE_NUM" -lt 1 ] || [ "$NODE_NUM" -gt 20 ]; then
    echo -e "${RED}Error: node_number must be between 1 and 20${NC}"
    exit 1
fi

# ---- Auto-detect SD card ----

if [ -z "$SD_ROOT" ]; then
    echo "[+] Auto-detecting SD card rootfs..."

    case "$(uname)" in
        Darwin)
            # macOS: look for /Volumes/rootfs
            if [ -d "/Volumes/rootfs" ]; then
                SD_ROOT="/Volumes/rootfs"
            else
                # Look for any volume that looks like a Pi rootfs
                for vol in /Volumes/*; do
                    if [ -d "$vol/etc/systemd" ] && [ -d "$vol/opt" ]; then
                        SD_ROOT="$vol"
                        break
                    fi
                done
            fi
            ;;
        Linux)
            # Linux: check common mount points
            for mount in /media/"$USER"/rootfs /mnt/rootfs /media/rootfs; do
                if [ -d "$mount/etc/systemd" ]; then
                    SD_ROOT="$mount"
                    break
                fi
            done
            # Try lsblk to find mounted partitions
            if [ -z "$SD_ROOT" ]; then
                root_mount=$(lsblk -o MOUNTPOINT -nr 2>/dev/null | grep -E "^/media|^/mnt" | while read -r mp; do
                    if [ -d "$mp/etc/systemd" ]; then
                        echo "$mp"
                        break
                    fi
                done)
                SD_ROOT="${root_mount:-}"
            fi
            ;;
    esac

    if [ -z "$SD_ROOT" ]; then
        echo -e "${RED}Error: Could not auto-detect SD card rootfs${NC}"
        echo "Please specify the path manually:"
        echo "  $0 $NODE_NUM /path/to/rootfs"
        echo ""
        echo "On macOS, insert the SD card and look for /Volumes/rootfs"
        echo "On Linux, check /media/\$USER/ or /mnt/"
        exit 1
    fi
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

# Get this node's specific config
IP_VAR="PI${NODE_NUM}_MESH_IP"
NAME_VAR="PI${NODE_NUM}_SERVER_NAME"
NODE_IP="${!IP_VAR:-}"
NODE_NAME="${!NAME_VAR:-node${NODE_NUM}.nightwatch.irc}"

if [ -z "$NODE_IP" ]; then
    # Generate IP from node number
    NODE_IP="192.168.199.$((100 + NODE_NUM))"
    echo -e "${YELLOW}[!] PI${NODE_NUM}_MESH_IP not in .env.example — using $NODE_IP${NC}"
fi

echo ""
echo -e "${BOLD}${CYAN}======================================"
echo "  Nightwatch SD Card Preparation"
echo "======================================${NC}"
echo ""
echo "  Node:       Pi #$NODE_NUM"
echo "  Name:       $NODE_NAME"
echo "  Mesh IP:    $NODE_IP"
echo "  Gateway:    $GATEWAY_MODE"
echo "  SD card:    $SD_ROOT"
echo ""

# Confirm
echo -e "${YELLOW}This will write to $SD_ROOT/opt/nightwatch/${NC}"
read -rp "Continue? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ---- Step 1: Copy project ----

echo "[1/4] Copying project to SD card..."
DEST="$SD_ROOT/opt/nightwatch"
sudo mkdir -p "$DEST"

# Copy everything except .git, .env, and generated files
sudo rsync -a --delete \
    --exclude='.git' \
    --exclude='.env' \
    --exclude='ngircd/ngircd.conf' \
    --exclude='*.log' \
    --exclude='.DS_Store' \
    --exclude='node_modules' \
    --exclude='irc-bridge-go/irc-bridge' \
    "$PROJECT_DIR/" "$DEST/"

echo "[+] Project copied to $DEST"

# ---- Step 2: Generate node-specific .env ----

echo "[2/4] Generating .env for Pi #$NODE_NUM..."

# Build the .env by modifying the template
ENV_DEST="$DEST/.env"
sudo cp "$ENV_TEMPLATE" "$ENV_DEST"

# Override node-specific values
sudo sed -i.bak "s/^PI_NUMBER=.*/PI_NUMBER=$NODE_NUM/" "$ENV_DEST"
sudo sed -i.bak "s/^MESH_IP=.*/MESH_IP=$NODE_IP/" "$ENV_DEST"

if [ "$GATEWAY_MODE" = true ]; then
    sudo sed -i.bak "s/^MESH_GATEWAY=.*/MESH_GATEWAY=true/" "$ENV_DEST"
    sudo sed -i.bak "s/^# INET_IFACE=eth0/INET_IFACE=eth0/" "$ENV_DEST"
fi

# Clean up sed backup files
sudo rm -f "$ENV_DEST.bak"

echo "[+] .env written:"
echo "    PI_NUMBER=$NODE_NUM"
echo "    MESH_IP=$NODE_IP"
echo "    MESH_GATEWAY=$GATEWAY_MODE"

# ---- Step 3: Install firstboot service ----

echo "[3/4] Installing firstboot service..."
sudo chmod +x "$DEST/scripts/firstboot.sh"
sudo chmod +x "$DEST/scripts/mesh-fix.sh"
sudo chmod +x "$DEST/scripts/setup-rpi.sh"
sudo chmod +x "$DEST/scripts/setup-distributed-irc.sh"

# Copy systemd service
sudo cp "$DEST/scripts/nightwatch-firstboot.service" \
    "$SD_ROOT/etc/systemd/system/nightwatch-firstboot.service"

# Enable it (create the symlink manually since systemctl won't work on a mounted FS)
sudo mkdir -p "$SD_ROOT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/nightwatch-firstboot.service \
    "$SD_ROOT/etc/systemd/system/multi-user.target.wants/nightwatch-firstboot.service"

echo "[+] Firstboot service installed and enabled"

# ---- Step 4: Verify ----

echo "[4/4] Verifying..."

ERRORS=0
for f in .env scripts/firstboot.sh scripts/mesh-fix.sh docker-compose.yml irc-bridge-go/Dockerfile html/index.html; do
    if [ ! -f "$DEST/$f" ]; then
        echo -e "  ${RED}[MISS] $f${NC}"
        ((ERRORS++))
    fi
done

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
echo "  Node:       Pi #$NODE_NUM ($NODE_NAME)"
echo "  Mesh IP:    $NODE_IP"
echo "  Gateway:    $GATEWAY_MODE"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "  1. Eject the SD card safely"
echo "  2. Insert into the Raspberry Pi"
echo "  3. Connect Ethernet (for first boot package install)"
echo "     OR ensure Pi Imager WiFi config gives internet access"
echo "  4. Power on — setup runs automatically (~5-10 min)"
echo "  5. Monitor progress: ssh into Pi, then:"
echo "     journalctl -f -u nightwatch-firstboot"
echo "     tail -f /var/log/nightwatch-firstboot.log"
echo ""
echo "  After first boot completes, the Pi will:"
echo "  • Start the mesh network automatically on every boot"
echo "  • Start Docker services (IRC, bridge, web UI)"
echo "  • Broadcast WiFi hotspot '${AP_SSID:-Nightwatch}'"
echo ""
