#!/bin/bash
# Nightwatch — Full Raspberry Pi setup (one command, one reboot)
#
# This script does EVERYTHING:
#   1. Asks for node number (or derives from hostname)
#   2. Sets hostname to nightwatch-<N>
#   3. Installs all system packages
#   4. Installs Docker + Docker Compose
#   5. Loads batman-adv, disables system hostapd
#   6. Saves project path to /etc/nightwatch.conf
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
INSTALL_DIR="$PROJECT_DIR"

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

echo "[1/10] Setting hostname to $NEW_HOSTNAME..."
hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || echo "$NEW_HOSTNAME" > /etc/hostname
# Update /etc/hosts
sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts 2>/dev/null || true
if ! grep -q "$NEW_HOSTNAME" /etc/hosts; then
    echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
fi
echo "[+] Hostname set to $NEW_HOSTNAME"

# ---- Step 2: Install packages ----

echo ""
echo "[2/10] Installing system packages..."
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
echo "[+] Packages installed"

# Disable system dnsmasq — we start our own instance on br0 via mesh-fix.sh
systemctl disable dnsmasq 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# ---- Step 3: Docker Compose ----

echo ""
echo "[3/10] Installing Docker Compose..."
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

# ---- Step 4: batman-adv ----

echo ""
echo "[4/10] Setting up batman-adv..."
modprobe batman-adv || true
if ! grep -q "^batman-adv" /etc/modules 2>/dev/null; then
    echo "batman-adv" >> /etc/modules
fi
echo "[+] batman-adv version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'loads on boot')"

# Disable hostapd — AP is handled by the external GL.iNet router, not the Pi
systemctl disable hostapd 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true

# ---- Step 4b: Network routing ----
# Architecture:
#   wlan0 = internet + Tailscale (WiFi client, never touch)
#   wlan1 = 802.11s mesh (USB dongle, batman-adv)
#   eth0  = GL.iNet router (external AP for clients, bridged into batman-adv)

echo ""
echo "[4b/10] Configuring network routing..."

DHCPCD_CONF="/etc/dhcpcd.conf"
if [ -f "$DHCPCD_CONF" ]; then
    # Remove old broken Nightwatch config if present (had nogateway on eth0)
    if grep -q "# Nightwatch network config" "$DHCPCD_CONF"; then
        sed -i '/# Nightwatch network config/,/^$/d' "$DHCPCD_CONF"
        # Also clean up any leftover directives
        sed -i '/# eth0 is the GL.iNet/d; /# wlan0 has internet/d; /# Fallback DNS when Tailscale/d' "$DHCPCD_CONF"
        echo "[+] Removed old Nightwatch dhcpcd config"
    fi
    if ! grep -q "# Nightwatch DNS" "$DHCPCD_CONF"; then
        cat >> "$DHCPCD_CONF" << 'NETEOF'

# Nightwatch DNS — hardcode DNS so we don't depend on DHCP-provided nameservers
static domain_name_servers=8.8.8.8 1.1.1.1
NETEOF
        echo "[+] dhcpcd configured: static DNS 8.8.8.8 + 1.1.1.1"
    else
        echo "[+] dhcpcd DNS already configured for Nightwatch"
    fi
    # Tell dhcpcd to ignore eth0 and bat0 — they are bridge ports managed by mesh-fix.sh
    # Without this, dhcpcd tries to get a DHCP lease on eth0, conflicting with br0
    if ! grep -q "denyinterfaces eth0" "$DHCPCD_CONF"; then
        cat >> "$DHCPCD_CONF" << 'DENYEOF'

# Nightwatch bridge — dhcpcd must not manage these (br0 bridge handles them)
denyinterfaces eth0 bat0 br0
DENYEOF
        echo "[+] dhcpcd: eth0/bat0/br0 excluded (bridge ports)"
    else
        echo "[+] dhcpcd already excludes eth0"
    fi
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

# Apply immediately (don't wait for reboot)

# Tell Tailscale to stop overwriting /etc/resolv.conf
if command -v tailscale >/dev/null 2>&1; then
    tailscale set --accept-dns=false 2>/dev/null || true
    echo "[+] Tailscale DNS disabled (--accept-dns=false)"
fi

# Make /etc/resolv.conf immutable so nothing can overwrite it
# (Tailscale, dhcpcd, NetworkManager all fight over this file)
chattr -i /etc/resolv.conf 2>/dev/null || true
cat > /etc/resolv.conf << 'DNSEOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
DNSEOF
chattr +i /etc/resolv.conf
echo "[+] /etc/resolv.conf locked (immutable) with 8.8.8.8 + 1.1.1.1"

# Restart dhcpcd to pick up new config (removes old nogateway on eth0)
systemctl restart dhcpcd 2>/dev/null || true

# ---- Step 5: Register project path ----

echo ""
echo "[5/10] Registering Nightwatch directory..."
echo "NIGHTWATCH_DIR=$INSTALL_DIR" > /etc/nightwatch.conf
chmod +x "$INSTALL_DIR"/scripts/*.sh
echo "[+] Project path saved to /etc/nightwatch.conf ($INSTALL_DIR)"

# ---- Step 6: Generate .env ----

echo ""
echo "[6/10] Generating configuration..."
ENV_FILE="$INSTALL_DIR/.env"
cp "$INSTALL_DIR/.env.example" "$ENV_FILE"

sed -i "s/^PI_NUMBER=.*/PI_NUMBER=$NODE_NUM/" "$ENV_FILE"
sed -i "s/^MESH_IP=.*/MESH_IP=$MESH_IP/" "$ENV_FILE"

if [ "$IS_GATEWAY" = true ]; then
    sed -i "s/^MESH_GATEWAY=.*/MESH_GATEWAY=true/" "$ENV_FILE"
    sed -i "s/^# INET_IFACE=wlan0/INET_IFACE=wlan0/" "$ENV_FILE"
fi

# Set router password (prompt if not already in .env from a previous install)
if grep -q "CHANGE_ME_BEFORE_DEPLOY" "$ENV_FILE"; then
    echo ""
    echo -e "  ${BOLD}Set passwords for IRC and router:${NC}"
    read -rsp "  Router admin password: " ROUTER_PWD
    echo ""
    read -rsp "  IRC link password: " IRC_PWD
    echo ""
    # Single-quote passwords in .env to prevent $, !, etc. from being
    # interpreted by docker compose or bash
    sed -i "s/^ROUTER_PASSWORD=.*/ROUTER_PASSWORD='$ROUTER_PWD'/" "$ENV_FILE"
    sed -i "s/^IRC_LINK_PASSWORD=.*/IRC_LINK_PASSWORD='$IRC_PWD'/" "$ENV_FILE"
fi

echo "[+] .env generated (PI_NUMBER=$NODE_NUM, MESH_IP=$MESH_IP, GATEWAY=$IS_GATEWAY)"

# Generate ngircd config
cd "$INSTALL_DIR"
if [ -x scripts/setup-distributed-irc.sh ]; then
    scripts/setup-distributed-irc.sh
    echo "[+] ngircd.conf generated"
fi

# Generate dnsmasq config for client DHCP + captive portal
echo "[+] Generating dnsmasq config..."
DHCP_START=$((200 + (NODE_NUM - 1) * 5 + 1))
DHCP_END=$((200 + (NODE_NUM - 1) * 5 + 5))
MESH_IP_PLAIN="${MESH_IP%/*}"
mkdir -p "$INSTALL_DIR/dnsmasq"
cat > "$INSTALL_DIR/dnsmasq/dnsmasq.conf" << DNSEOF
# Nightwatch dnsmasq — DHCP + captive portal DNS for WiFi clients
# Auto-generated by setup-rpi.sh — do not edit manually

# Only listen on the mesh bridge
interface=br0
bind-interfaces

# DHCP range for WiFi clients (each node gets 5 addresses to avoid conflicts)
dhcp-range=192.168.199.${DHCP_START},192.168.199.${DHCP_END},255.255.255.0,1h

# Tell clients to use this node as gateway and DNS
dhcp-option=3,${MESH_IP_PLAIN}
dhcp-option=6,${MESH_IP_PLAIN}

# Redirect ALL DNS to this node (captive portal)
# Every domain resolves to the local Pi — phone detects "no internet" and
# opens captive portal popup, which shows the Nightwatch chat page.
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

# ---- Step 7: Install systemd services ----

echo ""
echo "[7/10] Installing systemd services..."

# Generate service files with actual project path
sed "s|/opt/nightwatch|$INSTALL_DIR|g" "$INSTALL_DIR/scripts/nightwatch-nodeconfig.service" > /etc/systemd/system/nightwatch-nodeconfig.service
sed "s|/opt/nightwatch|$INSTALL_DIR|g" "$INSTALL_DIR/scripts/nightwatch-mesh.service" > /etc/systemd/system/nightwatch-mesh.service
sed "s|/opt/nightwatch|$INSTALL_DIR|g" "$INSTALL_DIR/scripts/nightwatch-discovery.service" > /etc/systemd/system/nightwatch-discovery.service

# Docker service needs docker compose detection too
if docker compose version >/dev/null 2>&1; then
    DC_BIN="/usr/bin/docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC_BIN="$(command -v docker-compose)"
else
    DC_BIN="/usr/bin/docker compose"
fi
sed -e "s|/opt/nightwatch|$INSTALL_DIR|g" \
    -e "s|/usr/bin/docker compose|$DC_BIN|g" \
    "$INSTALL_DIR/scripts/nightwatch-docker.service" > /etc/systemd/system/nightwatch-docker.service

systemctl daemon-reload
# Remove old DNS workaround service if present (Tailscale --accept-dns=false is the proper fix)
systemctl disable nightwatch-dns.service 2>/dev/null || true
rm -f /etc/systemd/system/nightwatch-dns.service
systemctl enable nightwatch-nodeconfig.service
systemctl enable nightwatch-mesh.service
systemctl enable nightwatch-discovery.service
systemctl enable nightwatch-docker.service

echo "[+] Services installed and enabled:"
echo "    • nightwatch-nodeconfig (generates config from hostname)"
echo "    • nightwatch-mesh (802.11s + batman-adv + AP)"
echo "    • nightwatch-discovery (UDP broadcast node discovery)"
echo "    • nightwatch-docker (IRC + bridge + nginx)"

# ---- Step 8: Build Docker images ----

echo ""
echo "[8/10] Building Docker images (this may take a few minutes)..."
cd "$INSTALL_DIR"

# Detect docker compose command (v2 plugin vs v1 standalone)
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "[-] Neither 'docker compose' nor 'docker-compose' found!"
    exit 1
fi

$DC --env-file .env build
echo "[+] Docker images built"

# ---- Step 9: Configure GL.iNet router ----

echo ""
echo "[9/10] Configuring GL.iNet router..."

# Check if router is already configured by SSHing to the configured IP
# and verifying the WiFi SSID matches what we want
ROUTER_CONFIGURED_IP="${ROUTER_CONFIGURED_IP:-192.168.8.100}"
ROUTER_PASSWORD_CHECK=$(grep '^ROUTER_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
WIFI_SSID_CHECK=$(grep '^WIFI_SSID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
ROUTER_ALREADY_CONFIGURED=false

if [ -n "$ROUTER_PASSWORD_CHECK" ] && [ "$ROUTER_PASSWORD_CHECK" != "CHANGE_ME_BEFORE_DEPLOY" ] && command -v sshpass >/dev/null 2>&1; then
    # Temporarily give eth0 an IP to reach the router
    ip addr add 192.168.8.2/24 dev eth0 2>/dev/null || true
    ip link set eth0 up 2>/dev/null || true
    sleep 1
    if ping -c 1 -W 2 "$ROUTER_CONFIGURED_IP" >/dev/null 2>&1; then
        SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
        CURRENT_SSID=$(sshpass -p "$ROUTER_PASSWORD_CHECK" ssh $SSH_OPTS root@"$ROUTER_CONFIGURED_IP" \
            "uci get wireless.@wifi-iface[0].ssid 2>/dev/null" 2>/dev/null || echo "")
        if [ "$CURRENT_SSID" = "$WIFI_SSID_CHECK" ]; then
            ROUTER_ALREADY_CONFIGURED=true
        fi
    fi
    ip addr del 192.168.8.2/24 dev eth0 2>/dev/null || true
fi

if [ "$ROUTER_ALREADY_CONFIGURED" = true ]; then
    echo -e "  ${GREEN}[+] Router already configured (SSID: $CURRENT_SSID at $ROUTER_CONFIGURED_IP)${NC}"
    echo "  Skipping. To reconfigure: sudo scripts/setup-router.sh"
else
    # Try to configure — if it fails, let the user retry or skip
    while true; do
        if "$INSTALL_DIR/scripts/setup-router.sh"; then
            break
        fi
        echo ""
        echo -e "  ${YELLOW}[!] Router not found.${NC}"
        echo "      Plug the router into eth0 and press ${BOLD}r${NC} to retry"
        echo "      or press ${BOLD}s${NC} to skip (you can do it later with: make router)"
        read -rp "  [r/s] " router_choice
        case "$router_choice" in
            [Ss]) echo "  Skipping router setup."; break ;;
            *)    echo "  Retrying..." ;;
        esac
    done
fi

# ---- Step 10: Verify ----

echo ""
echo "[10/10] Verifying installation..."

ERRORS=0
for f in .env scripts/mesh-fix.sh scripts/nodeconfig.sh scripts/node-discovery.sh scripts/setup-router.sh docker-compose.yml irc-bridge-go/Dockerfile html/index.html ngircd/ngircd.conf dnsmasq/dnsmasq.conf; do
    if [ -f "$INSTALL_DIR/$f" ]; then
        echo -e "  ${GREEN}[OK]${NC} $f"
    else
        echo -e "  ${RED}[MISS]${NC} $f"
        ((ERRORS++))
    fi
done

for svc in nightwatch-nodeconfig nightwatch-mesh nightwatch-discovery nightwatch-docker; do
    if systemctl is-enabled "$svc" >/dev/null 2>&1; then
        echo -e "  ${GREEN}[OK]${NC} $svc.service enabled"
    else
        echo -e "  ${RED}[MISS]${NC} $svc.service not enabled"
        ((ERRORS++))
    fi
done

echo ""
MESH_IFACE_CHECK="${MESH_IFACE:-wlan1}"
echo "[+] Verifying mesh support on $MESH_IFACE_CHECK..."
phy=$(iw dev "$MESH_IFACE_CHECK" info 2>/dev/null | grep wiphy | awk '{print $2}')
if [ -n "$phy" ]; then
    mesh_support=$(iw phy "phy${phy}" info 2>/dev/null | grep "mesh point" || true)
    if [ -n "$mesh_support" ]; then
        echo -e "  ${GREEN}[OK]${NC} $MESH_IFACE_CHECK (phy${phy}): mesh point supported"
    else
        echo -e "  ${RED}[FAIL]${NC} $MESH_IFACE_CHECK (phy${phy}): mesh point NOT supported — wrong USB dongle?"
        ((ERRORS++))
    fi
else
    echo -e "  ${YELLOW}[!]${NC} $MESH_IFACE_CHECK not found — is the USB WiFi dongle plugged in?"
fi

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
echo "  Bridge:   br0 (bat0 + eth0 → GL.iNet router)"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "    sudo reboot"
echo "    cd $INSTALL_DIR"
echo "    make run"
echo "    make test"
echo ""
