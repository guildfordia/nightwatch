#!/bin/bash
# Nightwatch — Full Raspberry Pi setup (one command, one reboot)
#
# This script does EVERYTHING:
#   1. Asks for node number (or derives from hostname)
#   2. Sets hostname to nightwatch-<N>
#   3. Installs all system packages
#   4. Installs app services (ngircd, nginx, irc-bridge)
#   5. Loads batman-adv, disables system hostapd
#   6. Saves project path to /etc/nightwatch.conf
#   7. Generates .env + ngircd.conf from node number
#   8. Installs systemd services (nodeconfig, mesh, app services)
#   9. Verifies irc-bridge binary
#   10. Tells you to reboot — everything starts automatically
#
# Usage:
#   sudo ./scripts/setup-rpi.sh              # Interactive (asks for node number)
#   sudo ./scripts/setup-rpi.sh 3            # Node 3
#   sudo ./scripts/setup-rpi.sh 5 --gateway  # Node 5, gateway mode
#   sudo ./scripts/setup-rpi.sh 5 --mode sound-bridge  # Node 5, sound-bridge mode
#
# After reboot, the boot sequence is:
#   nodeconfig → generates .env from hostname
#   mesh       → starts 802.11s + batman-adv + hostapd AP
#   nightwatch-app → starts IRC + bridge + nginx

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="$PROJECT_DIR"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

# ---- Parse arguments ----

NODE_NUM=""
NODE_MODE=""
IS_GATEWAY=false

ARGS=("$@")
i=0
while [ $i -lt ${#ARGS[@]} ]; do
    arg="${ARGS[$i]}"
    case "$arg" in
        --gateway|-gw) NODE_MODE="gateway"; IS_GATEWAY=true ;;
        --mode)        i=$((i+1)); NODE_MODE="${ARGS[$i]:-mesh}" ;;
        [0-9]*)        NODE_NUM="$arg" ;;
    esac
    i=$((i+1))
done

# Backward compat: --gateway sets NODE_MODE=gateway
if [ "$IS_GATEWAY" = true ] && [ -z "$NODE_MODE" ]; then
    NODE_MODE="gateway"
fi
NODE_MODE="${NODE_MODE:-mesh}"

# Validate mode
case "$NODE_MODE" in
    mesh|gateway|sound-bridge) ;;
    *) echo -e "${RED}Error: invalid mode '$NODE_MODE' (valid: mesh, gateway, sound-bridge)${NC}"; exit 1 ;;
esac
IS_GATEWAY=$( [ "$NODE_MODE" = "gateway" ] && echo true || echo false )

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

# Ask about mode if not specified via flag (only for default mesh mode)
if [ "$NODE_MODE" = "mesh" ]; then
    echo ""
    echo -e "  ${BOLD}Node mode:${NC}"
    echo "    1) mesh          (default — hostapd AP on wlan2)"
    echo "    2) gateway       (internet sharing via wlan0)"
    echo "    3) sound-bridge  (eth0 to Mac Mini for nightwatch-sound)"
    read -rp "  Choose mode [1]: " mode_choice
    case "$mode_choice" in
        2) NODE_MODE="gateway"; IS_GATEWAY=true ;;
        3) NODE_MODE="sound-bridge" ;;
        *) NODE_MODE="mesh" ;;
    esac
fi

MESH_IP="$(mesh_ip_for_node "$NODE_NUM")"
case "$NODE_MODE" in
    gateway)      NEW_HOSTNAME="nightwatch-gw-${NODE_NUM}" ;;
    sound-bridge) NEW_HOSTNAME="nightwatch-sb-${NODE_NUM}" ;;
    *)            NEW_HOSTNAME="nightwatch-${NODE_NUM}" ;;
esac

echo ""
echo -e "  ${BOLD}Node:${NC}     #$NODE_NUM"
echo -e "  ${BOLD}Hostname:${NC} $NEW_HOSTNAME"
echo -e "  ${BOLD}Mesh IP:${NC}  $MESH_IP"
echo -e "  ${BOLD}Mode:${NC}     $NODE_MODE"
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
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ngircd \
    nginx \
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
    sshpass \
    firmware-atheros \
    hostapd
echo "[+] Packages installed"

# Disable system dnsmasq — we start our own instance on br0 via mesh-fix.sh
systemctl disable dnsmasq 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# ---- Step 3: Configure native services ----

echo ""
echo "[3/10] Configuring native services (ngircd, nginx, irc-bridge)..."

# Stop default services — Nightwatch manages them via systemd
systemctl stop ngircd 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl disable ngircd 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

# Symlink nginx config
rm -f /etc/nginx/sites-enabled/default
ln -sf "$INSTALL_DIR/nginx/nginx.conf" /etc/nginx/conf.d/nightwatch.conf

# Symlink nginx html root
rm -rf /usr/share/nginx/html
ln -sf "$INSTALL_DIR/html" /usr/share/nginx/html

# Generate self-signed certs for captive portal HTTPS redirect (if missing)
CERT_DIR="$INSTALL_DIR/nginx/certs"
if [ ! -f "$CERT_DIR/captive.crt" ] || [ ! -f "$CERT_DIR/captive.key" ]; then
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CERT_DIR/captive.key" \
        -out "$CERT_DIR/captive.crt" \
        -subj "/CN=nightwatch.local" 2>/dev/null
    echo "[+] Self-signed TLS cert generated for captive portal"
fi
ln -sf "$CERT_DIR" /etc/nginx/certs

# Symlink ngircd config
ln -sf "$INSTALL_DIR/ngircd/ngircd.conf" /etc/ngircd/ngircd.conf

# Create data dir for irc-bridge nick counter
mkdir -p "$INSTALL_DIR/irc-bridge-go/data"
chown "$REAL_USER:$REAL_USER" "$INSTALL_DIR/irc-bridge-go/data"

# Ensure irc-bridge binary is executable
chmod +x "$INSTALL_DIR/irc-bridge-go/irc-bridge" 2>/dev/null || true

echo "[+] Native services configured"

# ---- Step 4: batman-adv ----

echo ""
echo "[4/10] Setting up batman-adv..."
modprobe batman-adv || true
if ! grep -q "^batman-adv" /etc/modules 2>/dev/null; then
    echo "batman-adv" >> /etc/modules
fi
echo "[+] batman-adv version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'loads on boot')"

# Disable system hostapd — mesh-fix.sh starts hostapd manually with our config
systemctl disable hostapd 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true

# ---- Step 4b: Network routing ----
# Architecture:
#   wlan0 = internet + Tailscale (WiFi client, never touch)
#   wlan1 = 802.11s mesh (USB dongle 1, batman-adv)
#   wlan2 = hostapd WiFi AP (USB dongle 2, 802.11r fast roaming)

echo ""
echo "[4b/10] Configuring network routing..."

configure_network

# Persistent WiFi dongle names (prevent wlan1/wlan2 swap after driver reload)
setup_persistent_wifi_names

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

set_env_value "$ENV_FILE" "PI_NUMBER" "$NODE_NUM"
set_env_value "$ENV_FILE" "MESH_IP" "$MESH_IP"

set_env_value "$ENV_FILE" "NODE_MODE" "$NODE_MODE"
if [ "$NODE_MODE" = "gateway" ]; then
    set_env_value "$ENV_FILE" "INET_IFACE" "wlan0"
fi

# Set router password (prompt if not already in .env from a previous install)
if grep -q "CHANGE_ME_BEFORE_DEPLOY" "$ENV_FILE"; then
    echo ""
    echo -e "  ${BOLD}Set passwords for IRC and router:${NC}"
    read -rsp "  Router admin password: " ROUTER_PWD
    echo ""
    read -rsp "  IRC link password: " IRC_PWD
    echo ""
    # Use set_env_value for safe password injection (no sed escaping issues)
    set_env_value "$ENV_FILE" "ROUTER_PASSWORD" "$ROUTER_PWD"
    set_env_value "$ENV_FILE" "IRC_LINK_PASSWORD" "$IRC_PWD"
fi

echo "[+] .env generated (PI_NUMBER=$NODE_NUM, MESH_IP=$MESH_IP, MODE=$NODE_MODE)"

# Generate ngircd config
cd "$INSTALL_DIR"
if [ -x scripts/setup-distributed-irc.sh ]; then
    scripts/setup-distributed-irc.sh
    echo "[+] ngircd.conf generated"
fi

# Generate dnsmasq config for client DHCP + captive portal
echo "[+] Generating dnsmasq config..."
generate_dnsmasq_conf "$INSTALL_DIR/dnsmasq/dnsmasq.conf" "$NODE_NUM" "$MESH_IP"
DHCP_START=$((200 + (NODE_NUM - 1) * 5 + 1))
DHCP_END=$((200 + (NODE_NUM - 1) * 5 + 5))
echo "[+] dnsmasq.conf generated (DHCP: .${DHCP_START}-.${DHCP_END})"

# ---- Step 7: Install systemd services ----

echo ""
echo "[7/10] Installing systemd services..."

install_systemd_services "$INSTALL_DIR"

echo "[+] Services installed and enabled:"
echo "    • nightwatch-nodeconfig (generates config from hostname)"
echo "    • nightwatch-mesh (802.11s + batman-adv + AP)"
echo "    • nightwatch-discovery (UDP broadcast node discovery)"
echo "    • nightwatch-app (IRC + bridge + nginx orchestrator)"
echo "    • nightwatch-led (green LED readiness indicator)"
echo "    • nightwatch-debug (debug info collector)"

# ---- Step 8: Verify irc-bridge binary ----

echo ""
echo "[8/10] Verifying irc-bridge binary..."
if [ -x "$INSTALL_DIR/irc-bridge-go/irc-bridge" ]; then
    echo "[+] irc-bridge binary found ($( ls -lh "$INSTALL_DIR/irc-bridge-go/irc-bridge" | awk '{print $5}'))"
else
    echo -e "${RED}[-] irc-bridge binary not found!${NC}"
    echo "    Cross-compile on your laptop: cd irc-bridge-go && make build-bridge"
    echo "    Or copy a pre-built binary to $INSTALL_DIR/irc-bridge-go/irc-bridge"
    echo ""
    echo -e "${RED}    Setup cannot continue without the bridge binary.${NC}"
    exit 1
fi

# ---- Step 9: Generate hostapd config ----

echo ""
echo "[9/10] Generating hostapd config (WiFi AP with 802.11r fast roaming)..."

WIFI_SSID_VAL=$(grep '^WIFI_SSID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "Nightwatch")
WIFI_PASSWORD_VAL=$(grep '^WIFI_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "Nightwatch")
AP_CHANNEL_VAL=$(grep '^AP_CHANNEL=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "6")
AP_BSSID_VAL=$(grep '^AP_BSSID=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "02:00:4E:57:00:01")
AP_IFACE_VAL=$(grep '^AP_IFACE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- || echo "wlan2")

mkdir -p "$INSTALL_DIR/hostapd"
generate_hostapd_conf "$INSTALL_DIR/hostapd/hostapd.conf" \
    "$AP_IFACE_VAL" "br0" \
    "$WIFI_SSID_VAL" "$WIFI_PASSWORD_VAL" \
    "$AP_CHANNEL_VAL" "$AP_BSSID_VAL"
echo "[+] hostapd.conf generated (SSID: $WIFI_SSID_VAL, Channel: $AP_CHANNEL_VAL, BSSID: $AP_BSSID_VAL)"

# ---- Step 10: Verify ----

echo ""
echo "[10/10] Verifying installation..."

ERRORS=0
for f in .env scripts/mesh-fix.sh scripts/nodeconfig.sh scripts/node-discovery.sh irc-bridge-go/irc-bridge html/index.html ngircd/ngircd.conf dnsmasq/dnsmasq.conf hostapd/hostapd.conf nginx/nginx.conf; do
    if [ -f "$INSTALL_DIR/$f" ]; then
        echo -e "  ${GREEN}[OK]${NC} $f"
    else
        echo -e "  ${RED}[MISS]${NC} $f"
        ((ERRORS++))
    fi
done

for svc in nightwatch-nodeconfig nightwatch-mesh nightwatch-discovery nightwatch-app nightwatch-led nightwatch-debug; do
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
echo "  Mode:     $NODE_MODE"
if [ "$NODE_MODE" = "sound-bridge" ]; then
echo "  Bridge:   br0 (bat0 only) + eth0 → Mac Mini (10.0.0.1/24)"
else
echo "  Bridge:   br0 (bat0 + wlan2 → hostapd AP)"
fi
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "    sudo reboot"
echo "    cd $INSTALL_DIR"
echo "    make run"
echo "    make test"
echo ""
