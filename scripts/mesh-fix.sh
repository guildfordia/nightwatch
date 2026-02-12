#!/bin/bash
# Nightwatch mesh network script
# 802.11s + batman-adv + hostapd AP bridged into bat0
#
# Architecture:
#   wlan1 (USB dongle) → 802.11s mesh → batman-adv (bat0) → IP
#   wlan0 (onboard)    → hostapd AP   → bridged into bat0
#   Clients connect to AP, traffic flows through mesh via bat0

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# Load .env
if [ ! -f "$ENV_FILE" ]; then
    echo "[-] Error: $ENV_FILE not found. Run 'make prepare-env' first."
    exit 1
fi
set -o allexport
source "$ENV_FILE"
set +o allexport

# Defaults
MESH_IFACE="${MESH_IFACE:-wlan1}"
AP_IFACE="${AP_IFACE:-wlan0}"
BAT_IFACE="${BAT_IFACE:-bat0}"
MESH_ID="${MESH_ID:-nightwatch}"
FREQ="${FREQ:-2412}"
MESH_SAE_PASSWORD="${MESH_SAE_PASSWORD:-}"
AP_SSID="${AP_SSID:-Nightwatch}"
AP_PASSWORD="${AP_PASSWORD:-}"
AP_CHANNEL="${AP_CHANNEL:-6}"

if [ -z "$MESH_IP" ]; then
    echo "[-] Error: MESH_IP not set in $ENV_FILE"
    exit 1
fi

# Ensure CIDR notation
if [[ "$MESH_IP" != *"/"* ]]; then
    MESH_IP="${MESH_IP}/24"
fi

# ---- Helper functions ----

load_batman_module() {
    if ! lsmod | grep -q batman_adv; then
        echo "[+] Loading batman-adv kernel module..."
        modprobe batman-adv
    fi
    echo "[+] batman-adv version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'unknown')"
}

setup_mesh_interface() {
    echo "[+] Configuring $MESH_IFACE for 802.11s mesh..."

    # Bring down and reset
    ip link set "$MESH_IFACE" down 2>/dev/null || true
    iw dev "$MESH_IFACE" set type mesh 2>/dev/null || true
    ip link set "$MESH_IFACE" up

    sleep 1

    # Join 802.11s mesh
    if [ -n "$MESH_SAE_PASSWORD" ]; then
        echo "[+] Joining encrypted mesh '$MESH_ID' on $FREQ MHz (SAE)..."
        # SAE encryption requires wpa_supplicant — generate config
        cat > /tmp/nightwatch-mesh-wpa.conf << WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
network={
    ssid="$MESH_ID"
    mode=5
    frequency=$FREQ
    key_mgmt=SAE
    sae_password="$MESH_SAE_PASSWORD"
    ieee80211w=2
    mesh_fwding=0
}
WPAEOF
        wpa_supplicant -B -i "$MESH_IFACE" -c /tmp/nightwatch-mesh-wpa.conf -D nl80211
    else
        echo "[+] Joining open mesh '$MESH_ID' on $FREQ MHz..."
        iw dev "$MESH_IFACE" mesh join "$MESH_ID" freq "$FREQ"
        # Disable HWMP forwarding — batman-adv handles routing
        echo 0 > /sys/class/net/"$MESH_IFACE"/mesh/mesh_fwding 2>/dev/null || true
    fi

    sleep 1
    echo "[+] 802.11s mesh interface ready"
}

setup_batman() {
    echo "[+] Setting up batman-adv on $BAT_IFACE..."

    # Add mesh interface to batman
    batctl meshif "$BAT_IFACE" if add "$MESH_IFACE" 2>/dev/null || \
        batctl if add "$MESH_IFACE" 2>/dev/null || true

    # Bring up bat0
    ip link set "$BAT_IFACE" up

    # Assign IP to bat0
    ip addr flush dev "$BAT_IFACE" 2>/dev/null || true
    ip addr add "$MESH_IP" dev "$BAT_IFACE"

    # Set batman-adv routing algorithm (BATMAN_V is preferred for newer versions)
    # batctl ra BATMAN_V 2>/dev/null || true

    # Enable distributed ARP table for efficiency
    batctl meshif "$BAT_IFACE" dat 1 2>/dev/null || \
        batctl dat 1 2>/dev/null || true

    # Enable bridge loop avoidance (needed when AP is bridged)
    batctl meshif "$BAT_IFACE" bla 1 2>/dev/null || \
        batctl bla 1 2>/dev/null || true

    echo "[+] batman-adv $BAT_IFACE is up with IP ${MESH_IP%/*}"
}

setup_ap() {
    echo "[+] Configuring access point on $AP_IFACE..."

    # Stop any existing hostapd
    killall hostapd 2>/dev/null || true
    sleep 1

    # Generate hostapd config
    local HOSTAPD_CONF="/tmp/nightwatch-hostapd.conf"
    cat > "$HOSTAPD_CONF" << APEOF
interface=$AP_IFACE
driver=nl80211
ssid=$AP_SSID
hw_mode=g
channel=$AP_CHANNEL
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
APEOF

    if [ -n "$AP_PASSWORD" ] && [ ${#AP_PASSWORD} -ge 8 ]; then
        cat >> "$HOSTAPD_CONF" << APEOF
wpa=2
wpa_passphrase=$AP_PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
APEOF
        echo "[+] AP '$AP_SSID' configured with WPA2 password"
    else
        echo "[+] AP '$AP_SSID' configured as open network (no password)"
    fi

    # Bring up AP interface
    ip link set "$AP_IFACE" down 2>/dev/null || true
    ip link set "$AP_IFACE" up

    # Add AP interface to batman-adv (bridges client traffic into mesh)
    batctl meshif "$BAT_IFACE" if add "$AP_IFACE" 2>/dev/null || \
        batctl if add "$AP_IFACE" 2>/dev/null || true

    # Start hostapd
    hostapd -B "$HOSTAPD_CONF"
    sleep 1

    echo "[+] Access point '$AP_SSID' is broadcasting"
}

setup_gateway() {
    if [ "$MESH_GATEWAY" = "true" ]; then
        echo "[+] Configuring this node as a mesh gateway..."
        batctl meshif "$BAT_IFACE" gw_mode server 2>/dev/null || \
            batctl gw_mode server 2>/dev/null || true

        # Enable IP forwarding for internet sharing
        sysctl -w net.ipv4.ip_forward=1 > /dev/null

        # NAT for internet-bound traffic (assumes eth0 for internet)
        local INET_IFACE="${INET_IFACE:-eth0}"
        iptables -t nat -A POSTROUTING -o "$INET_IFACE" -j MASQUERADE 2>/dev/null || true
        iptables -A FORWARD -i "$BAT_IFACE" -o "$INET_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -i "$INET_IFACE" -o "$BAT_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

        echo "[+] Gateway mode enabled (NAT via $INET_IFACE)"
    else
        batctl meshif "$BAT_IFACE" gw_mode client 2>/dev/null || \
            batctl gw_mode client 2>/dev/null || true
        echo "[+] Gateway mode: client (will use mesh gateway if available)"
    fi
}

# ---- Main actions ----

case "$1" in
    start)
        echo "====================================="
        echo "  Nightwatch Mesh Network Starting"
        echo "====================================="
        echo ""

        load_batman_module
        setup_mesh_interface
        setup_batman
        setup_ap
        setup_gateway

        echo ""
        echo "====================================="
        echo "  Mesh network is UP"
        echo "  Mesh IP: ${MESH_IP%/*}"
        echo "  AP SSID: $AP_SSID"
        echo "====================================="
        ;;

    stop)
        echo "[+] Stopping Nightwatch mesh network..."

        # Stop hostapd
        killall hostapd 2>/dev/null || true

        # Remove interfaces from batman
        batctl meshif "$BAT_IFACE" if del "$AP_IFACE" 2>/dev/null || \
            batctl if del "$AP_IFACE" 2>/dev/null || true
        batctl meshif "$BAT_IFACE" if del "$MESH_IFACE" 2>/dev/null || \
            batctl if del "$MESH_IFACE" 2>/dev/null || true

        # Bring down bat0
        ip link set "$BAT_IFACE" down 2>/dev/null || true

        # Leave mesh
        killall wpa_supplicant 2>/dev/null || true
        iw dev "$MESH_IFACE" mesh leave 2>/dev/null || true
        ip addr flush dev "$MESH_IFACE" 2>/dev/null || true
        ip link set "$MESH_IFACE" down 2>/dev/null || true

        # Clean up AP
        ip link set "$AP_IFACE" down 2>/dev/null || true

        # Remove gateway NAT rules
        iptables -t nat -F POSTROUTING 2>/dev/null || true

        echo "[+] Mesh network stopped"
        ;;

    status)
        echo "==============================="
        echo "  Nightwatch Mesh Status"
        echo "==============================="
        echo ""

        echo "== batman-adv =="
        if [ -d /sys/class/net/"$BAT_IFACE" ]; then
            echo "  Version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'N/A')"
            echo "  Algorithm: $(batctl meshif $BAT_IFACE ra 2>/dev/null || batctl ra 2>/dev/null || echo 'N/A')"
            echo "  Gateway mode: $(batctl meshif $BAT_IFACE gw_mode 2>/dev/null || batctl gw_mode 2>/dev/null || echo 'N/A')"
            echo "  IP: $(ip -4 addr show dev $BAT_IFACE 2>/dev/null | grep inet | awk '{print $2}' || echo 'none')"
        else
            echo "  [!] $BAT_IFACE not found"
        fi

        echo ""
        echo "== 802.11s Mesh ($MESH_IFACE) =="
        if iw dev "$MESH_IFACE" info 2>/dev/null | grep -q mesh; then
            iw dev "$MESH_IFACE" info 2>/dev/null | grep -E "type|channel|txpower" | sed 's/^/  /'
            echo ""
            echo "  Mesh peers:"
            iw dev "$MESH_IFACE" station dump 2>/dev/null | grep -E "Station|signal:|mesh plink:" | sed 's/^/    /' || echo "    (none)"
        else
            echo "  [!] Not in mesh mode"
        fi

        echo ""
        echo "== batman-adv Neighbors =="
        batctl meshif "$BAT_IFACE" n 2>/dev/null || batctl n 2>/dev/null || echo "  (none)"

        echo ""
        echo "== batman-adv Originators (full mesh) =="
        batctl meshif "$BAT_IFACE" o 2>/dev/null || batctl o 2>/dev/null || echo "  (none)"

        echo ""
        echo "== batman-adv Gateways =="
        batctl meshif "$BAT_IFACE" gwl 2>/dev/null || batctl gwl 2>/dev/null || echo "  (none)"

        echo ""
        echo "== Access Point ($AP_IFACE) =="
        if pgrep -x hostapd > /dev/null 2>&1; then
            echo "  Status: running"
            echo "  SSID: $AP_SSID"
            echo "  Clients:"
            iw dev "$AP_IFACE" station dump 2>/dev/null | grep -E "Station|signal:" | sed 's/^/    /' || echo "    (none)"
        else
            echo "  [!] hostapd not running"
        fi

        echo ""
        echo "== Interfaces in batman-adv =="
        batctl meshif "$BAT_IFACE" if 2>/dev/null || batctl if 2>/dev/null || echo "  (none)"
        ;;

    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
