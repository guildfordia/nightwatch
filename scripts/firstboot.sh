#!/bin/bash
# Nightwatch — First boot autonomous setup
# This script runs ONCE on the Pi's first boot, then disables itself.
#
# It expects the project to already be at /opt/nightwatch (copied by prepare-sdcard.sh)
# and a valid .env to be present with this node's configuration.
#
# What it does:
#   1. Wait for network (to apt install)
#   2. Install all system dependencies
#   3. Install Docker + Docker Compose
#   4. Load batman-adv, disable system hostapd
#   5. Setup distributed IRC config
#   6. Install mesh systemd service
#   7. Build Docker images
#   8. Start mesh + services
#   9. Disable this firstboot service

set -euo pipefail

NIGHTWATCH_DIR="/opt/nightwatch"
LOG_FILE="/var/log/nightwatch-firstboot.log"
STAMP_FILE="/opt/nightwatch/.firstboot-done"

# Redirect all output to log + console
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "======================================"
echo "  Nightwatch First Boot Setup"
echo "  $(date)"
echo "======================================"
echo ""

# Skip if already completed
if [ -f "$STAMP_FILE" ]; then
    echo "[+] First boot already completed. Skipping."
    exit 0
fi

if [ ! -d "$NIGHTWATCH_DIR" ]; then
    echo "[-] Error: $NIGHTWATCH_DIR not found"
    echo "[-] The project must be copied to $NIGHTWATCH_DIR before first boot"
    exit 1
fi

cd "$NIGHTWATCH_DIR"

if [ ! -f ".env" ]; then
    echo "[-] Error: .env not found in $NIGHTWATCH_DIR"
    exit 1
fi

# Load config for logging
set -o allexport
# shellcheck source=/dev/null
source .env
set +o allexport

echo "[+] Node: Pi #${PI_NUMBER:-?} — IP: ${MESH_IP:-?}"
echo ""

# ---- Step 1: Wait for network ----

echo "[1/9] Waiting for network..."
TRIES=0
MAX_TRIES=30
while ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; do
    ((TRIES++))
    if [ "$TRIES" -ge "$MAX_TRIES" ]; then
        echo "[-] No internet after ${MAX_TRIES} attempts."
        echo "[-] Connect Ethernet or configure WiFi, then run: sudo systemctl start nightwatch-firstboot"
        exit 1
    fi
    echo "  Waiting... ($TRIES/$MAX_TRIES)"
    sleep 5
done
echo "[+] Network is up"

# ---- Step 2: Install system packages ----

echo ""
echo "[2/9] Installing system packages..."
apt-get update -qq
apt-get install -y -qq \
    docker.io \
    batctl \
    iproute2 \
    iw \
    wireless-tools \
    net-tools \
    hostapd \
    wpasupplicant \
    iptables \
    curl \
    git \
    fping \
    netcat-openbsd
echo "[+] System packages installed"

# ---- Step 3: Install Docker Compose ----

echo ""
echo "[3/9] Installing Docker Compose..."
if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64) COMPOSE_ARCH="linux-aarch64" ;;
        armv7l|armhf)  COMPOSE_ARCH="linux-armv7" ;;
        x86_64)        COMPOSE_ARCH="linux-x86_64" ;;
        *)             echo "[-] Unsupported arch: $ARCH"; exit 1 ;;
    esac
    COMPOSE_VERSION="v2.24.6"
    curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-${COMPOSE_ARCH}" \
        -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    echo "[+] Docker Compose $COMPOSE_VERSION installed"
else
    echo "[+] Docker Compose already available"
fi

# Enable Docker to start on boot
systemctl enable docker
systemctl start docker

# Add default user to docker group
DEFAULT_USER=$(find /home/ -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -1)
if [ -n "$DEFAULT_USER" ]; then
    usermod -aG docker "$DEFAULT_USER"
    echo "[+] Added $DEFAULT_USER to docker group"
fi

# ---- Step 4: Setup batman-adv & hostapd ----

echo ""
echo "[4/9] Setting up batman-adv..."
modprobe batman-adv || true
if ! grep -q "^batman-adv" /etc/modules 2>/dev/null; then
    echo "batman-adv" >> /etc/modules
fi
echo "[+] batman-adv version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'loading on next boot')"

echo "[+] Disabling system hostapd service..."
systemctl unmask hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true

# ---- Step 5: Setup distributed IRC ----

echo ""
echo "[5/9] Setting up distributed IRC..."
if [ -x scripts/setup-distributed-irc.sh ]; then
    cd "$NIGHTWATCH_DIR"
    scripts/setup-distributed-irc.sh
    echo "[+] IRC configuration generated"
else
    echo "[!] setup-distributed-irc.sh not found, skipping"
fi

# ---- Step 6: Install mesh systemd service ----

echo ""
echo "[6/9] Installing mesh service..."
chmod +x scripts/mesh-fix.sh
cp scripts/nightwatch-mesh.service /etc/systemd/system/nightwatch-mesh.service
systemctl daemon-reload
systemctl enable nightwatch-mesh.service
echo "[+] Mesh service installed and enabled"

# ---- Step 7: Build Docker images ----

echo ""
echo "[7/9] Building Docker images (this may take a few minutes)..."
cd "$NIGHTWATCH_DIR"
docker compose --env-file .env build
echo "[+] Docker images built"

# ---- Step 8: Start everything ----

echo ""
echo "[8/9] Starting mesh network..."
systemctl start nightwatch-mesh.service
sleep 5

echo "[+] Starting Docker services..."
docker compose --env-file .env up -d
sleep 3
echo "[+] Services started"

# ---- Step 9: Mark complete & disable firstboot ----

echo ""
echo "[9/9] Finalizing..."

# Create stamp file
date > "$STAMP_FILE"
echo "Pi #${PI_NUMBER} — ${MESH_IP}" >> "$STAMP_FILE"

# Disable firstboot service (we don't need it again)
systemctl disable nightwatch-firstboot.service 2>/dev/null || true

echo ""
echo "======================================"
echo "  Nightwatch First Boot Complete!"
echo "  Node:    Pi #${PI_NUMBER}"
echo "  Mesh IP: ${MESH_IP}"
echo "  AP SSID: ${AP_SSID:-Nightwatch}"
echo ""
echo "  Web UI:  http://${MESH_IP%/*}"
echo "  Log:     $LOG_FILE"
echo "======================================"
