#!/bin/bash
# Nightwatch mesh network script
# 802.11s + batman-adv + hostapd AP bridged into bat0
#
# Architecture:
#   wlan1 (USB dongle) → 802.11s mesh → batman-adv (bat0) → IP
#   wlan0 (onboard)    → hostapd AP   → bridged into bat0
#   Clients connect to AP, traffic flows through mesh via bat0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# Load .env
if [ ! -f "$ENV_FILE" ]; then
    echo "[-] Error: $ENV_FILE not found. Run 'make prepare-env' first."
    exit 1
fi
set -o allexport
# shellcheck source=/dev/null
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

setup_client_bridge() {
    echo "[+] Bridging $AP_IFACE into batman-adv (client access via external router)..."

    # Ensure the interface is up
    ip link set "$AP_IFACE" up 2>/dev/null || true
    sleep 1

    # Remove any IP address from AP_IFACE — batman interfaces must not have IPs
    # (the router handles DHCP/IP, bat0 has the mesh IP)
    ip addr flush dev "$AP_IFACE" 2>/dev/null || true

    # Bridge into batman-adv so clients on the router can reach the mesh
    local bridged=false
    for attempt in 1 2 3; do
        if batctl meshif "$BAT_IFACE" if add "$AP_IFACE" 2>/dev/null || \
           batctl if add "$AP_IFACE" 2>/dev/null; then
            bridged=true
            break
        fi
        echo "[!] batctl if add $AP_IFACE attempt $attempt failed, retrying..."
        sleep 2
    done

    if $bridged; then
        echo "[+] $AP_IFACE bridged into $BAT_IFACE — router clients can reach mesh"
    else
        echo "[-] Failed to bridge $AP_IFACE into $BAT_IFACE"
        return 1
    fi
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
        setup_client_bridge || echo "[!] Client bridge setup failed — mesh still operational"
        setup_gateway

        echo ""
        echo "====================================="
        echo "  Mesh network is UP"
        echo "  Mesh IP: ${MESH_IP%/*}"
        echo "  Client bridge: $AP_IFACE"
        echo "====================================="
        ;;

    stop)
        echo "[+] Stopping Nightwatch mesh network..."

        # Remove interfaces from batman
        batctl meshif "$BAT_IFACE" if del "$AP_IFACE" 2>/dev/null || \
            batctl if del "$AP_IFACE" 2>/dev/null || true
        batctl meshif "$BAT_IFACE" if del "$MESH_IFACE" 2>/dev/null || \
            batctl if del "$MESH_IFACE" 2>/dev/null || true

        # Bring down bat0
        ip link set "$BAT_IFACE" down 2>/dev/null || true

        # Leave mesh (only kill mesh wpa_supplicant, not internet wpa_supplicant)
        pkill -f "nightwatch-mesh-wpa" 2>/dev/null || true
        iw dev "$MESH_IFACE" mesh leave 2>/dev/null || true
        ip addr flush dev "$MESH_IFACE" 2>/dev/null || true
        ip link set "$MESH_IFACE" down 2>/dev/null || true

        # NOTE: wlan0 and eth0 are never touched here — wlan0 provides internet,
        # eth0 connects to the external router (both must stay up)

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
            echo "  Algorithm: $(batctl meshif "$BAT_IFACE" ra 2>/dev/null || batctl ra 2>/dev/null || echo 'N/A')"
            echo "  Gateway mode: $(batctl meshif "$BAT_IFACE" gw_mode 2>/dev/null || batctl gw_mode 2>/dev/null || echo 'N/A')"
            echo "  IP: $(ip -4 addr show dev "$BAT_IFACE" 2>/dev/null | grep inet | awk '{print $2}' || echo 'none')"
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
        echo "== Client Bridge ($AP_IFACE) =="
        if batctl meshif "$BAT_IFACE" if 2>/dev/null | grep -q "$AP_IFACE"; then
            echo "  Status: $AP_IFACE bridged into $BAT_IFACE"
        else
            echo "  [!] $AP_IFACE NOT bridged into $BAT_IFACE"
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
