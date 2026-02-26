#!/bin/bash
# Nightwatch — First boot autonomous setup
# This script runs ONCE on the Pi's first boot, then disables itself.
#
# It expects the project to be at /opt/nightwatch (or path in /etc/nightwatch.conf)
# and a valid .env to be present with this node's configuration (passwords baked in).
#
# What it does:
#   1. Wait for network (to apt install)
#   2. Install all system dependencies
#   3. Install Docker + Docker Compose
#   4. Load batman-adv, disable system hostapd/dnsmasq
#   5. Configure dhcpcd + DNS (resolv.conf locked)
#   6. Install Tailscale (if TAILSCALE_AUTH_KEY set)
#   7. Setup distributed IRC config
#   8. Generate dnsmasq config
#   9. Install all systemd services (nodeconfig, mesh, discovery, docker)
#  10. Build Docker images
#  11. Start everything
#  12. Disable this firstboot service
#
# Designed for the "flash and forget" workflow:
#   1. Flash Pi OS with Pi Imager (set hostname, SSH, WiFi, user)
#   2. Run prepare-sdcard.sh to bake project + secrets onto the card
#   3. Boot — this script does the rest, fully unattended

set -euo pipefail

# Read project path from /etc/nightwatch.conf
if [ -f /etc/nightwatch.conf ]; then
    # shellcheck source=/dev/null
    source /etc/nightwatch.conf
fi
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-/opt/nightwatch}"
LOG_FILE="/var/log/nightwatch-firstboot.log"
STAMP_FILE="$NIGHTWATCH_DIR/.firstboot-done"

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

# If .env doesn't exist, run nodeconfig first to generate it (dynamic mode)
if [ ! -f ".env" ]; then
    echo "[+] No .env found — running nodeconfig for dynamic node assignment..."
    if [ -x scripts/nodeconfig.sh ]; then
        scripts/nodeconfig.sh
    else
        echo "[-] Error: .env not found and nodeconfig.sh not available"
        exit 1
    fi
fi

if [ ! -f ".env" ]; then
    echo "[-] Error: .env still not found after nodeconfig"
    exit 1
fi

# Load config
set -o allexport
# shellcheck source=/dev/null
source .env
set +o allexport

# Detect the real user (not root)
REAL_USER=$(find /home/ -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | head -1)
REAL_USER="${REAL_USER:-pi}"

echo "[+] Node: Pi #${PI_NUMBER:-?} — IP: ${MESH_IP:-?}"
echo "[+] User: $REAL_USER"
echo ""

# ---- Step 1: Wait for network ----

echo "[1/12] Waiting for network..."
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

# ---- Step 1b: Sync clock (Pi has no hardware RTC) ----

echo "[1b/12] Syncing system clock..."
# Without correct time, apt signature verification fails ("Not live until ...")
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true 2>/dev/null || true
    # Wait up to 30s for NTP sync
    for i in $(seq 1 15); do
        if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
            break
        fi
        sleep 2
    done
fi
# Fallback: fetch time from HTTP header if NTP didn't work
if [ "$(date +%Y)" -lt 2026 ]; then
    HTTP_DATE=$(curl -sI http://deb.debian.org 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //')
    if [ -n "$HTTP_DATE" ]; then
        date -s "$HTTP_DATE" 2>/dev/null || true
        echo "[+] Clock set from HTTP: $(date)"
    else
        echo "[!] Warning: could not sync clock — apt may fail"
    fi
else
    echo "[+] Clock OK: $(date)"
fi

# ---- Step 1c: Ensure SSH host keys exist ----
# build-image.sh deletes SSH keys for cloning; regenerate if missing
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    echo "[1c/12] Regenerating SSH host keys..."
    ssh-keygen -A >/dev/null 2>&1 || true
    systemctl restart sshd 2>/dev/null || true
    echo "[+] SSH host keys regenerated"
fi

# ---- Step 2: Install system packages ----

echo ""
echo "[2/12] Installing system packages..."
apt-get update -qq
apt-get install -y -qq \
    docker.io \
    batctl \
    bridge-utils \
    dnsmasq \
    iproute2 \
    iw \
    wireless-tools \
    net-tools \
    wpasupplicant \
    iptables \
    curl \
    git \
    fping \
    netcat-openbsd \
    socat \
    sshpass
echo "[+] System packages installed"

# Disable system dnsmasq — we start our own instance on br0 via mesh-fix.sh
systemctl disable dnsmasq 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# ---- Step 3: Install Docker Compose ----

echo ""
echo "[3/12] Installing Docker Compose..."
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
if [ -n "$REAL_USER" ]; then
    usermod -aG docker "$REAL_USER"
    echo "[+] Added $REAL_USER to docker group"
fi

# ---- Step 4: Setup batman-adv ----

echo ""
echo "[4/12] Setting up batman-adv..."
modprobe batman-adv || true
if ! grep -q "^batman-adv" /etc/modules 2>/dev/null; then
    echo "batman-adv" >> /etc/modules
fi
echo "[+] batman-adv version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'loads on boot')"

# Disable system services we don't need
systemctl disable hostapd 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true

# ---- Step 5: Configure network (dhcpcd + DNS) ----

echo ""
echo "[5/12] Configuring network routing..."

DHCPCD_CONF="/etc/dhcpcd.conf"
if [ -f "$DHCPCD_CONF" ]; then
    # Static DNS
    if ! grep -q "# Nightwatch DNS" "$DHCPCD_CONF"; then
        cat >> "$DHCPCD_CONF" << 'NETEOF'

# Nightwatch DNS — hardcode DNS so we don't depend on DHCP-provided nameservers
static domain_name_servers=8.8.8.8 1.1.1.1
NETEOF
        echo "[+] dhcpcd configured: static DNS 8.8.8.8 + 1.1.1.1"
    fi
    # Deny bridge port interfaces
    if ! grep -q "denyinterfaces eth0" "$DHCPCD_CONF"; then
        cat >> "$DHCPCD_CONF" << 'DENYEOF'

# Nightwatch bridge — dhcpcd must not manage these (br0 bridge handles them)
denyinterfaces eth0 bat0 br0
DENYEOF
        echo "[+] dhcpcd: eth0/bat0/br0 excluded (bridge ports)"
    fi
    systemctl restart dhcpcd 2>/dev/null || true
elif command -v nmcli >/dev/null 2>&1; then
    # NetworkManager: configure eth0 — no default route (it's a bridge port to GL.iNet AP)
    ETH_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep 'eth0' | head -1 | cut -d: -f1)
    if [ -n "$ETH_CON" ]; then
        # eth0 must NOT add a default route — it connects to the GL.iNet AP (no internet)
        # Without this, eth0's route (metric 100) wins over wlan0 (metric 600) and
        # all traffic goes to the GL.iNet bridge which has no upstream internet.
        nmcli con mod "$ETH_CON" ipv4.never-default yes 2>/dev/null || true
        nmcli con mod "$ETH_CON" ipv4.dns "8.8.8.8 1.1.1.1" 2>/dev/null || true
        nmcli con up "$ETH_CON" 2>/dev/null || true
        echo "[+] NetworkManager: eth0 ($ETH_CON) — never-default route, DNS 8.8.8.8 + 1.1.1.1"
    fi
    # Also add fallback via systemd-resolved
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/nightwatch-fallback.conf << 'DNSEOF'
[Resolve]
FallbackDNS=8.8.8.8 1.1.1.1
DNSEOF
    systemctl restart systemd-resolved 2>/dev/null || true
    echo "[+] Fallback DNS configured (8.8.8.8, 1.1.1.1)"
else
    echo "[!] Neither dhcpcd nor NetworkManager found — skipping network config"
fi

# Lock /etc/resolv.conf (prevents Tailscale, dhcpcd, etc. from overwriting)
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << 'DNSEOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
DNSEOF
chattr +i /etc/resolv.conf
echo "[+] /etc/resolv.conf locked (immutable) with 8.8.8.8 + 1.1.1.1"

# ---- Step 6: Install Tailscale ----

echo ""
echo "[6/12] Tailscale setup..."
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    if ! command -v tailscale >/dev/null 2>&1; then
        echo "[+] Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
        echo "[+] Tailscale installed"
    else
        echo "[+] Tailscale already installed"
    fi

    systemctl enable tailscaled
    systemctl start tailscaled

    # Join the tailnet unattended with the auth key
    echo "[+] Joining tailnet with auth key..."
    tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --accept-routes --accept-dns=false --hostname="$(hostname)" --reset

    # Wait for connection
    sleep 3
    TAILSCALE_IP=$(tailscale ip --4 2>/dev/null || echo "pending")
    echo "[+] Tailscale connected: $TAILSCALE_IP"
else
    echo "[+] No TAILSCALE_AUTH_KEY set — skipping Tailscale"
fi

# ---- Step 7: Setup distributed IRC config ----

echo ""
echo "[7/12] Setting up distributed IRC..."
if [ -x scripts/setup-distributed-irc.sh ]; then
    cd "$NIGHTWATCH_DIR"
    scripts/setup-distributed-irc.sh
    echo "[+] IRC configuration generated"
else
    echo "[!] setup-distributed-irc.sh not found, skipping"
fi

# ---- Step 8: Generate dnsmasq config ----

echo ""
echo "[8/12] Generating dnsmasq config..."
NODE_NUM="${PI_NUMBER:-1}"
DHCP_START=$((200 + (NODE_NUM - 1) * 5 + 1))
DHCP_END=$((200 + (NODE_NUM - 1) * 5 + 5))
MESH_IP_PLAIN="${MESH_IP%/*}"
mkdir -p "$NIGHTWATCH_DIR/dnsmasq"
cat > "$NIGHTWATCH_DIR/dnsmasq/dnsmasq.conf" << DNSEOF
# Nightwatch dnsmasq — DHCP + captive portal DNS for WiFi clients
# Auto-generated by firstboot.sh — do not edit manually

# Only listen on the mesh bridge
interface=br0
bind-interfaces

# DHCP range for WiFi clients (each node gets 5 addresses to avoid conflicts)
dhcp-range=192.168.199.${DHCP_START},192.168.199.${DHCP_END},255.255.255.0,1h

# Tell clients to use this node as gateway and DNS
dhcp-option=3,${MESH_IP_PLAIN}
dhcp-option=6,${MESH_IP_PLAIN}

# Redirect ALL DNS to this node (captive portal)
address=/#/${MESH_IP_PLAIN}

# Don't read /etc/resolv.conf (we handle all DNS ourselves)
no-resolv

# Don't poll /etc/resolv.conf for changes
no-poll

# Log DHCP leases (useful for debugging)
log-dhcp

# PID file for mesh-fix.sh to manage
pid-file=/var/run/dnsmasq-nightwatch.pid
DNSEOF
echo "[+] dnsmasq.conf generated (DHCP: .${DHCP_START}-.${DHCP_END})"

# ---- Step 9: Install systemd services ----

echo ""
echo "[9/12] Installing systemd services..."

# Ensure scripts are executable
chmod +x "$NIGHTWATCH_DIR"/scripts/*.sh

# Detect docker compose command
if docker compose version >/dev/null 2>&1; then
    DC_BIN="/usr/bin/docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC_BIN="$(command -v docker-compose)"
else
    DC_BIN="/usr/bin/docker compose"
fi

# Install service files (replace /opt/nightwatch with actual path)
sed "s|/opt/nightwatch|$NIGHTWATCH_DIR|g" \
    "$NIGHTWATCH_DIR/scripts/nightwatch-nodeconfig.service" > /etc/systemd/system/nightwatch-nodeconfig.service

sed "s|/opt/nightwatch|$NIGHTWATCH_DIR|g" \
    "$NIGHTWATCH_DIR/scripts/nightwatch-mesh.service" > /etc/systemd/system/nightwatch-mesh.service

sed "s|/opt/nightwatch|$NIGHTWATCH_DIR|g" \
    "$NIGHTWATCH_DIR/scripts/nightwatch-discovery.service" > /etc/systemd/system/nightwatch-discovery.service

sed -e "s|/opt/nightwatch|$NIGHTWATCH_DIR|g" \
    -e "s|/usr/bin/docker compose|$DC_BIN|g" \
    "$NIGHTWATCH_DIR/scripts/nightwatch-docker.service" > /etc/systemd/system/nightwatch-docker.service

systemctl daemon-reload

# Remove old DNS workaround if present
systemctl disable nightwatch-dns.service 2>/dev/null || true
rm -f /etc/systemd/system/nightwatch-dns.service

# Enable all services
systemctl enable nightwatch-nodeconfig.service
systemctl enable nightwatch-mesh.service
systemctl enable nightwatch-discovery.service
systemctl enable nightwatch-docker.service

echo "[+] Services installed and enabled:"
echo "    - nightwatch-nodeconfig (generates config from hostname)"
echo "    - nightwatch-mesh (802.11s + batman-adv + bridge)"
echo "    - nightwatch-discovery (UDP broadcast node discovery)"
echo "    - nightwatch-docker (IRC + bridge + nginx)"

# ---- Step 10: Build Docker images ----

echo ""
echo "[10/12] Building Docker images (this may take a few minutes)..."
cd "$NIGHTWATCH_DIR"
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    DC="docker compose"
fi
$DC --env-file .env build
echo "[+] Docker images built"

# ---- Step 11: Start everything ----

echo ""
echo "[11/12] Starting mesh network..."
systemctl start nightwatch-mesh.service
sleep 5

echo "[+] Starting node discovery..."
systemctl start nightwatch-discovery.service 2>/dev/null || true

echo "[+] Starting Docker services..."
$DC --env-file .env up -d
sleep 3
echo "[+] Services started"

# ---- Step 12: Mark complete & disable firstboot ----

echo ""
echo "[12/12] Finalizing..."

# Create stamp file
date > "$STAMP_FILE"
echo "Pi #${PI_NUMBER} — ${MESH_IP}" >> "$STAMP_FILE"

# Disable firstboot service (we don't need it again)
systemctl disable nightwatch-firstboot.service 2>/dev/null || true

# Get Tailscale IP if available
TS_IP=""
if command -v tailscale >/dev/null 2>&1; then
    TS_IP=$(tailscale ip --4 2>/dev/null || echo "")
fi

echo ""
echo "======================================"
echo "  Nightwatch First Boot Complete!"
echo "  Node:       Pi #${PI_NUMBER}"
echo "  Mesh IP:    ${MESH_IP}"
echo "  AP SSID:    ${WIFI_SSID:-Nightwatch}"
if [ -n "$TS_IP" ]; then
echo "  Tailscale:  ${TS_IP}"
fi
echo ""
echo "  Web UI:     http://${MESH_IP_PLAIN}"
echo "  Log:        $LOG_FILE"
echo "======================================"
