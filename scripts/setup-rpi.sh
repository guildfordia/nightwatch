#!/bin/bash
# Nightwatch — Full Raspberry Pi setup (one command, one reboot)
#
# This script does EVERYTHING:
#   1. Asks for node number (or derives from hostname)
#   2. Sets hostname to nightwatch-<N>
#   3. Installs all system packages
#   4. Installs Docker + Docker Compose
#   5. Loads batman-adv, disables system hostapd
#   6. Copies project to /opt/nightwatch
#   7. Generates .env + ngircd.conf from node number
#   8. Installs systemd services (nodeconfig, mesh, docker)
#   9. Builds Docker images
#   10. Tells you to reboot — everything starts automatically
#
# Usage:
#   sudo ./scripts/setup-rpi.sh              # Interactive (asks for node number)
#   sudo ./scripts/setup-rpi.sh 3            # Node 3
#   sudo ./scripts/setup-rpi.sh 5 --gateway  # Node 5, gateway mode
#
# After reboot, the boot sequence is:
#   nodeconfig → generates .env from hostname
#   mesh       → starts 802.11s + batman-adv + hostapd AP
#   docker     → starts IRC + bridge + nginx

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="/opt/nightwatch"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ---- Parse arguments ----

NODE_NUM=""
IS_GATEWAY=false

for arg in "$@"; do
    case "$arg" in
        --gateway|-gw) IS_GATEWAY=true ;;
        [0-9]*)        NODE_NUM="$arg" ;;
    esac
done

# ---- Must be root ----

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: run with sudo${NC}"
    echo "  sudo $0 $*"
    exit 1
fi

# Detect the real user (not root)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"

echo ""
echo -e "${BOLD}======================================"
echo "  Nightwatch — Pi Setup"
echo "======================================${NC}"
echo ""

# ---- Get node number ----

# Try to derive from current hostname first
CURRENT_HOSTNAME=$(hostname)
if [ -z "$NODE_NUM" ] && [[ "$CURRENT_HOSTNAME" =~ ([0-9]+) ]]; then
    DETECTED="${BASH_REMATCH[1]}"
    echo -e "  Detected node ${BOLD}#$DETECTED${NC} from hostname '$CURRENT_HOSTNAME'"
    read -rp "  Use this? [Y/n] " confirm
    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        NODE_NUM="$DETECTED"
    fi
fi

# Still no number — ask
while [ -z "$NODE_NUM" ] || ! [[ "$NODE_NUM" =~ ^[0-9]+$ ]] || [ "$NODE_NUM" -lt 1 ] || [ "$NODE_NUM" -gt 20 ]; do
    read -rp "  Enter node number (1-20): " NODE_NUM
done

# Ask about gateway if not specified via flag
if [ "$IS_GATEWAY" = false ]; then
    read -rp "  Is this the gateway node (internet sharing)? [y/N] " gw_confirm
    if [[ "$gw_confirm" =~ ^[Yy]$ ]]; then
        IS_GATEWAY=true
    fi
fi

MESH_IP="192.168.199.$((100 + NODE_NUM))"
if [ "$IS_GATEWAY" = true ]; then
    NEW_HOSTNAME="nightwatch-gw-${NODE_NUM}"
else
    NEW_HOSTNAME="nightwatch-${NODE_NUM}"
fi

echo ""
echo -e "  ${BOLD}Node:${NC}     #$NODE_NUM"
echo -e "  ${BOLD}Hostname:${NC} $NEW_HOSTNAME"
echo -e "  ${BOLD}Mesh IP:${NC}  $MESH_IP"
echo -e "  ${BOLD}Gateway:${NC}  $IS_GATEWAY"
echo ""
read -rp "  Continue with setup? [Y/n] " final_confirm
if [[ "$final_confirm" =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ---- Step 1: Set hostname ----

echo "[1/9] Setting hostname to $NEW_HOSTNAME..."
hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || echo "$NEW_HOSTNAME" > /etc/hostname
# Update /etc/hosts
sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts 2>/dev/null || true
if ! grep -q "$NEW_HOSTNAME" /etc/hosts; then
    echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
fi
echo "[+] Hostname set to $NEW_HOSTNAME"

# ---- Step 2: Install packages ----

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
echo "[+] Packages installed"

# ---- Step 3: Docker Compose ----

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

systemctl enable docker
systemctl start docker
usermod -aG docker "$REAL_USER"
echo "[+] Docker ready ($REAL_USER added to docker group)"

# ---- Step 4: batman-adv + hostapd ----

echo ""
echo "[4/9] Setting up batman-adv..."
modprobe batman-adv || true
if ! grep -q "^batman-adv" /etc/modules 2>/dev/null; then
    echo "batman-adv" >> /etc/modules
fi
echo "[+] batman-adv version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'loads on boot')"

systemctl unmask hostapd 2>/dev/null || true
systemctl disable hostapd 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true
echo "[+] System hostapd disabled (we manage it ourselves)"

# ---- Step 4b: Network routing (eth0 = hotspot, wlan0 = internet) ----

echo ""
echo "[4b/9] Configuring network routing..."

DHCPCD_CONF="/etc/dhcpcd.conf"
if [ -f "$DHCPCD_CONF" ]; then
    # Only add if not already configured
    if ! grep -q "# Nightwatch network config" "$DHCPCD_CONF"; then
        cat >> "$DHCPCD_CONF" << 'NETEOF'

# Nightwatch network config
# eth0 is the GL.iNet hotspot (no internet) — do not use as default route
interface eth0
nogateway

# wlan0 has internet — prefer it for default route
interface wlan0
metric 50

# Fallback DNS when Tailscale resolver cannot reach upstream
static domain_name_servers=8.8.8.8 1.1.1.1
NETEOF
        echo "[+] dhcpcd configured: eth0=no gateway, wlan0=preferred, DNS fallback=8.8.8.8"
    else
        echo "[+] dhcpcd already configured for Nightwatch"
    fi
else
    echo "[!] /etc/dhcpcd.conf not found — skipping (NetworkManager may be in use)"
fi

# Apply immediately (don't wait for reboot)
ip route replace default via "$(ip route show dev wlan0 | grep default | awk '{print $3}')" dev wlan0 metric 50 2>/dev/null || true

# ---- Step 5: Copy project to /opt/nightwatch ----

echo ""
echo "[5/9] Installing Nightwatch to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
rsync -a --delete \
    --exclude='.git' \
    --exclude='.env' \
    --exclude='ngircd/ngircd.conf' \
    --exclude='*.log' \
    --exclude='.DS_Store' \
    --exclude='node_modules' \
    --exclude='irc-bridge-go/irc-bridge' \
    "$PROJECT_DIR/" "$INSTALL_DIR/"

chmod +x "$INSTALL_DIR"/scripts/*.sh
echo "[+] Project installed to $INSTALL_DIR"

# ---- Step 6: Generate .env ----

echo ""
echo "[6/9] Generating configuration..."
ENV_FILE="$INSTALL_DIR/.env"
cp "$INSTALL_DIR/.env.example" "$ENV_FILE"

sed -i "s/^PI_NUMBER=.*/PI_NUMBER=$NODE_NUM/" "$ENV_FILE"
sed -i "s/^MESH_IP=.*/MESH_IP=$MESH_IP/" "$ENV_FILE"

if [ "$IS_GATEWAY" = true ]; then
    sed -i "s/^MESH_GATEWAY=.*/MESH_GATEWAY=true/" "$ENV_FILE"
    sed -i "s/^# INET_IFACE=eth0/INET_IFACE=eth0/" "$ENV_FILE"
fi

echo "[+] .env generated (PI_NUMBER=$NODE_NUM, MESH_IP=$MESH_IP, GATEWAY=$IS_GATEWAY)"

# Generate ngircd config
cd "$INSTALL_DIR"
if [ -x scripts/setup-distributed-irc.sh ]; then
    scripts/setup-distributed-irc.sh
    echo "[+] ngircd.conf generated"
fi

# ---- Step 7: Install systemd services ----

echo ""
echo "[7/9] Installing systemd services..."

cp "$INSTALL_DIR/scripts/nightwatch-nodeconfig.service" /etc/systemd/system/
cp "$INSTALL_DIR/scripts/nightwatch-mesh.service" /etc/systemd/system/
cp "$INSTALL_DIR/scripts/nightwatch-docker.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable nightwatch-nodeconfig.service
systemctl enable nightwatch-mesh.service
systemctl enable nightwatch-docker.service

echo "[+] Services installed and enabled:"
echo "    • nightwatch-nodeconfig (generates config from hostname)"
echo "    • nightwatch-mesh (802.11s + batman-adv + AP)"
echo "    • nightwatch-docker (IRC + bridge + nginx)"

# ---- Step 8: Build Docker images ----

echo ""
echo "[8/9] Building Docker images (this may take a few minutes)..."
cd "$INSTALL_DIR"
docker compose --env-file .env build
echo "[+] Docker images built"

# ---- Step 9: Verify ----

echo ""
echo "[9/9] Verifying installation..."

ERRORS=0
for f in .env scripts/mesh-fix.sh scripts/nodeconfig.sh docker-compose.yml irc-bridge-go/Dockerfile html/index.html ngircd/ngircd.conf; do
    if [ -f "$INSTALL_DIR/$f" ]; then
        echo -e "  ${GREEN}[OK]${NC} $f"
    else
        echo -e "  ${RED}[MISS]${NC} $f"
        ((ERRORS++))
    fi
done

for svc in nightwatch-nodeconfig nightwatch-mesh nightwatch-docker; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} $svc.service enabled"
    else
        echo -e "  ${RED}[MISS]${NC} $svc.service not enabled"
        ((ERRORS++))
    fi
done

echo ""
echo "[+] Verifying mesh support on wireless interfaces..."
for iface in $(iw dev 2>/dev/null | grep Interface | awk '{print $2}'); do
    phy=$(iw dev "$iface" info 2>/dev/null | grep wiphy | awk '{print $2}')
    if [ -n "$phy" ]; then
        mesh_support=$(iw phy "phy${phy}" info 2>/dev/null | grep "mesh point" || true)
        if [ -n "$mesh_support" ]; then
            echo -e "  ${GREEN}[OK]${NC} $iface (phy${phy}): mesh point supported"
        else
            echo -e "  ${YELLOW}[!]${NC}  $iface (phy${phy}): mesh point NOT supported"
        fi
    fi
done

# ---- Done ----

echo ""
if [ "$ERRORS" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}======================================"
    echo "  Setup Complete!"
    echo "======================================${NC}"
else
    echo -e "${YELLOW}${BOLD}======================================"
    echo "  Setup Complete (with $ERRORS warnings)"
    echo "======================================${NC}"
fi
echo ""
echo "  Node:     #$NODE_NUM ($NEW_HOSTNAME)"
echo "  Mesh IP:  $MESH_IP"
echo "  Gateway:  $IS_GATEWAY"
echo "  AP SSID:  $(grep ^AP_SSID "$ENV_FILE" | cut -d= -f2)"
echo ""
echo -e "  ${BOLD}Reboot to start everything:${NC}"
echo "    sudo reboot"
echo ""
echo "  On reboot, the Pi will automatically:"
echo "    1. Configure itself from hostname"
echo "    2. Start mesh network (802.11s + batman-adv)"
echo "    3. Broadcast WiFi hotspot"
echo "    4. Start chat services (IRC + web UI)"
echo ""
echo "  After reboot, verify with:"
echo "    cd $INSTALL_DIR && make mesh-status"
echo "    cd $INSTALL_DIR && make test-mesh-quick"
echo ""
