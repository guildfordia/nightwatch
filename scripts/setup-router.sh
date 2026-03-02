#!/bin/bash
# Nightwatch — Configure GL.iNet GL-MT300N-V2 as a dumb AP
#
# Turns a factory-fresh (or already configured) GL.iNet router into
# a pure WiFi access point bridged into the Nightwatch mesh:
#   - Sets admin password
#   - Configures WiFi SSID + password (WPA2)
#   - Switches to bridge/dumb AP mode (no DHCP, no NAT, no firewall)
#   - Sets timezone
#   - Sets static management IP
#
# The Pi's dnsmasq (on br0) handles DHCP for WiFi clients.
#
# Usage:
#   sudo scripts/setup-router.sh          # Uses settings from .env
#   sudo scripts/setup-router.sh --skip   # Skip router setup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

load_env "$ENV_FILE"

# Config from .env
ROUTER_IP="${ROUTER_IP:-192.168.8.1}"
ROUTER_CONFIGURED_IP="${ROUTER_CONFIGURED_IP:-192.168.8.100}"
ROUTER_PASSWORD="${ROUTER_PASSWORD:-}"
WIFI_SSID="${WIFI_SSID:-Nightwatch}"
WIFI_PASSWORD="${WIFI_PASSWORD:-Nightwatch}"
AP_IFACE="${AP_IFACE:-eth0}"
TEMP_IP="192.168.8.2"

if [ -z "$ROUTER_PASSWORD" ] || [ "$ROUTER_PASSWORD" = "CHANGE_ME_BEFORE_DEPLOY" ]; then
    echo -e "${RED}Error: ROUTER_PASSWORD not set in .env${NC}"
    echo "  Set it before running router setup."
    exit 1
fi

if [ ${#WIFI_PASSWORD} -lt 8 ]; then
    echo -e "${RED}Error: WIFI_PASSWORD must be at least 8 characters${NC}"
    exit 1
fi

# Validate inputs to prevent shell injection in UCI commands sent over SSH
# Reject characters that would be interpreted by remote shell: ' \ $ ` " !
UNSAFE_CHARS='[\x27\\$`"!]'
if [[ "$WIFI_SSID" =~ $UNSAFE_CHARS ]]; then
    echo -e "${RED}Error: WIFI_SSID contains unsafe characters (no quotes, $, backticks, !, or backslashes)${NC}"
    exit 1
fi
if [[ "$WIFI_PASSWORD" =~ $UNSAFE_CHARS ]]; then
    echo -e "${RED}Error: WIFI_PASSWORD contains unsafe characters (no quotes, $, backticks, !, or backslashes)${NC}"
    exit 1
fi
if [[ "$ROUTER_PASSWORD" =~ $UNSAFE_CHARS ]]; then
    echo -e "${RED}Error: ROUTER_PASSWORD contains unsafe characters (no quotes, $, backticks, !, or backslashes)${NC}"
    exit 1
fi

# ---- Step 0: Temporary IP on eth0 to reach the router ----

echo "[+] Assigning temporary IP $TEMP_IP to $AP_IFACE..."

# Make sure eth0 is not in a bridge (it shouldn't be during install)
ip link set "$AP_IFACE" nomaster 2>/dev/null || true
ip addr flush dev "$AP_IFACE" 2>/dev/null || true
ip addr add "$TEMP_IP/24" dev "$AP_IFACE" 2>/dev/null || true
ip link set "$AP_IFACE" up

# ---- Step 1: Find the router ----

echo "[+] Looking for GL.iNet router..."

FOUND_IP=""
for try_ip in "$ROUTER_IP" "$ROUTER_CONFIGURED_IP"; do
    if ping -c 1 -W 2 "$try_ip" >/dev/null 2>&1; then
        FOUND_IP="$try_ip"
        echo -e "  ${GREEN}Found router at $FOUND_IP${NC}"
        break
    fi
done

if [ -z "$FOUND_IP" ]; then
    echo -e "${RED}[-] Router not found at $ROUTER_IP or $ROUTER_CONFIGURED_IP${NC}"
    echo ""
    echo "  Make sure:"
    echo "  1. The GL.iNet router is powered on"
    echo "  2. An ethernet cable connects the Pi's eth0 to the router's LAN port"
    echo "  3. The router is at factory defaults (hold reset 10s)"
    echo ""
    # Clean up temp IP
    ip addr del "$TEMP_IP/24" dev "$AP_IFACE" 2>/dev/null || true
    exit 1
fi

# ---- Step 2: Get SSH access ----

echo "[+] Attempting SSH connection..."

# Install sshpass if needed (should already be installed by setup-rpi.sh)
if ! command -v sshpass >/dev/null 2>&1; then
    apt-get install -y -qq sshpass
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"
SSH_OK=false
SSH_PASSWORD=""

# Try 1: Already configured with our password
if SSHPASS="$ROUTER_PASSWORD" sshpass -e ssh $SSH_OPTS root@"$FOUND_IP" "echo ok" 2>/dev/null | grep -q "ok"; then
    SSH_OK=true
    SSH_PASSWORD="$ROUTER_PASSWORD"
    echo -e "  ${GREEN}SSH connected (existing password)${NC}"
fi

# Try 2: Factory fresh — empty password
if [ "$SSH_OK" = false ]; then
    if SSHPASS="" sshpass -e ssh $SSH_OPTS root@"$FOUND_IP" "echo ok" 2>/dev/null | grep -q "ok"; then
        SSH_OK=true
        SSH_PASSWORD=""
        echo -e "  ${GREEN}SSH connected (factory fresh, no password)${NC}"
    fi
fi

# Try 3: Factory fresh — default "goodlife" password
if [ "$SSH_OK" = false ]; then
    if SSHPASS="goodlife" sshpass -e ssh $SSH_OPTS root@"$FOUND_IP" "echo ok" 2>/dev/null | grep -q "ok"; then
        SSH_OK=true
        SSH_PASSWORD="goodlife"
        echo -e "  ${GREEN}SSH connected (default password)${NC}"
    fi
fi

if [ "$SSH_OK" = false ]; then
    echo -e "${YELLOW}[!] Cannot SSH into the router automatically.${NC}"
    echo ""
    echo "  Please complete initial setup manually:"
    echo "  1. Open http://$FOUND_IP in a browser"
    echo "  2. Set the admin password to the value in your .env (ROUTER_PASSWORD)"
    echo "  3. Re-run: sudo scripts/setup-router.sh"
    echo ""
    ip addr del "$TEMP_IP/24" dev "$AP_IFACE" 2>/dev/null || true
    exit 1
fi

# ---- Step 3: Set admin password if factory fresh ----

if [ "$SSH_PASSWORD" != "$ROUTER_PASSWORD" ]; then
    echo "[+] Setting admin password..."
    # Use chpasswd for safer password setting (no shell expansion of password chars)
    SSHPASS="$SSH_PASSWORD" sshpass -e ssh $SSH_OPTS root@"$FOUND_IP" \
        "echo 'root:${ROUTER_PASSWORD}' | chpasswd" 2>/dev/null
    SSH_PASSWORD="$ROUTER_PASSWORD"
    echo -e "  ${GREEN}Password set${NC}"
fi

# ---- Step 4: Configure router via UCI ----

echo "[+] Configuring router as dumb AP..."

# Build the UCI configuration script
# This runs on the router via SSH
CONFIG_SCRIPT=$(cat << 'UCIEOF'
#!/bin/sh
set -e

echo "  [1/6] Setting WiFi..."
uci set wireless.@wifi-device[0].disabled='0'
uci set wireless.@wifi-iface[0].ssid='__WIFI_SSID__'
uci set wireless.@wifi-iface[0].encryption='psk2'
uci set wireless.@wifi-iface[0].key='__WIFI_PASSWORD__'
uci set wireless.@wifi-iface[0].network='lan'
uci set wireless.@wifi-iface[0].mode='ap'

echo "  [2/6] Setting timezone..."
uci set system.@system[0].timezone='CET-1CEST,M3.5.0,M10.5.0/3'
uci set system.@system[0].zonename='Europe/Paris'

echo "  [3/6] Setting static IP..."
uci set network.lan.ipaddr='__ROUTER_CONFIGURED_IP__'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.proto='static'
# No gateway — this is a dumb AP, no routing
uci delete network.lan.gateway 2>/dev/null || true
uci delete network.lan.dns 2>/dev/null || true

echo "  [4/6] Bridging WAN port into LAN (dumb AP)..."
# Get current LAN and WAN interfaces
LAN_IFNAME=$(uci get network.lan.ifname 2>/dev/null || echo "")
WAN_IFNAME=$(uci get network.wan.ifname 2>/dev/null || echo "")
# Add WAN port to LAN bridge (if not already there)
if [ -n "$WAN_IFNAME" ] && ! echo "$LAN_IFNAME" | grep -q "$WAN_IFNAME"; then
    uci set network.lan.ifname="$LAN_IFNAME $WAN_IFNAME"
fi
# Remove WAN interface
uci delete network.wan.ifname 2>/dev/null || true
uci delete network.wan 2>/dev/null || true
uci delete network.wan6 2>/dev/null || true

echo "  [5/6] Disabling DHCP + firewall..."
# Disable DHCP server (Pi's dnsmasq handles this)
uci set dhcp.lan.ignore='1'
# Disable IPv6 RA
uci set dhcp.lan.ra='' 2>/dev/null || true
uci delete dhcp.lan.dhcpv6 2>/dev/null || true
uci delete dhcp.lan.ra 2>/dev/null || true
# Disable services not needed in AP mode
/etc/init.d/dnsmasq disable 2>/dev/null || true
/etc/init.d/odhcpd disable 2>/dev/null || true
/etc/init.d/firewall disable 2>/dev/null || true

echo "  [6/6] Committing config..."
uci commit

echo "  [OK] Configuration complete"
UCIEOF
)

# Replace placeholders with actual values
CONFIG_SCRIPT="${CONFIG_SCRIPT//__WIFI_SSID__/$WIFI_SSID}"
CONFIG_SCRIPT="${CONFIG_SCRIPT//__WIFI_PASSWORD__/$WIFI_PASSWORD}"
CONFIG_SCRIPT="${CONFIG_SCRIPT//__ROUTER_CONFIGURED_IP__/$ROUTER_CONFIGURED_IP}"

# Execute on the router
SSHPASS="$SSH_PASSWORD" sshpass -e ssh $SSH_OPTS root@"$FOUND_IP" "$CONFIG_SCRIPT"

# ---- Step 5: Reboot the router ----

echo "[+] Rebooting router..."
echo "    Router will come back at $ROUTER_CONFIGURED_IP"
SSHPASS="$SSH_PASSWORD" sshpass -e ssh $SSH_OPTS root@"$FOUND_IP" "reboot" 2>/dev/null || true

# Clean up temporary IP
ip addr del "$TEMP_IP/24" dev "$AP_IFACE" 2>/dev/null || true

# Wait for router to come back
echo "[+] Waiting for router to reboot (this takes ~30s)..."
sleep 10
for i in $(seq 1 30); do
    # Re-add temp IP to check (it was cleaned up)
    ip addr add "$TEMP_IP/24" dev "$AP_IFACE" 2>/dev/null || true
    if ping -c 1 -W 2 "$ROUTER_CONFIGURED_IP" >/dev/null 2>&1; then
        echo -e "  ${GREEN}Router is back at $ROUTER_CONFIGURED_IP${NC}"
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo -e "${YELLOW}[!] Router hasn't responded yet. It may still be rebooting.${NC}"
        echo "    Check manually: ping $ROUTER_CONFIGURED_IP"
    fi
    sleep 2
done

# Final cleanup
ip addr del "$TEMP_IP/24" dev "$AP_IFACE" 2>/dev/null || true

echo ""
echo -e "${GREEN}${BOLD}Router configured successfully!${NC}"
echo "  WiFi SSID:      $WIFI_SSID"
echo "  WiFi Password:  ****"
echo "  Management IP:  $ROUTER_CONFIGURED_IP"
echo "  Mode:           Dumb AP (bridge, no DHCP)"
echo ""
