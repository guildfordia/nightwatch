#!/bin/bash
# Nightwatch mesh network script
# 802.11s + batman-adv + Linux bridge for client access
#
# Architecture:
#   wlan1 (USB dongle) → 802.11s mesh → batman-adv (bat0)
#   eth0  (GL.iNet)    → Linux bridge (br0) with bat0 → router clients reach mesh
#   wlan0 (onboard)    → internet + Tailscale (never touched)
#   br0 gets the mesh IP; bat0 and eth0 are bridge ports (no IPs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

load_env "$ENV_FILE"

# Defaults
MESH_IFACE="${MESH_IFACE:-wlan1}"
AP_IFACE="${AP_IFACE:-eth0}"
BAT_IFACE="${BAT_IFACE:-bat0}"
BR_IFACE="${BR_IFACE:-br0}"
MESH_ID="${MESH_ID:-nightwatch}"
FREQ="${FREQ:-2412}"
MESH_SAE_PASSWORD="${MESH_SAE_PASSWORD:-}"

if [ -z "$MESH_IP" ]; then
    echo "[-] Error: MESH_IP not set in $ENV_FILE"
    exit 1
fi

# Validate MESH_IP is a valid IPv4 address (strip CIDR suffix for check)
MESH_IP_CHECK="${MESH_IP%/*}"
if [[ ! "$MESH_IP_CHECK" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[-] Error: Invalid MESH_IP: $MESH_IP"
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

    # Kill anything holding the interface (NetworkManager, wpa_supplicant)
    nmcli dev set "$MESH_IFACE" managed no 2>/dev/null || true
    pkill -f "wpa_supplicant.*$MESH_IFACE" 2>/dev/null || true
    sleep 1
    # Force-kill if SIGTERM was ignored
    if pgrep -f "wpa_supplicant.*$MESH_IFACE" >/dev/null 2>&1; then
        pkill -9 -f "wpa_supplicant.*$MESH_IFACE" 2>/dev/null || true
        sleep 1
    fi

    # Bring down and set mesh type
    ip link set "$MESH_IFACE" down 2>/dev/null || true
    if ! iw dev "$MESH_IFACE" set type mesh; then
        echo "[-] Failed to set $MESH_IFACE to mesh mode, retrying..."
        sleep 2
        iw dev "$MESH_IFACE" set type mesh
    fi
    ip link set "$MESH_IFACE" up

    sleep 1

    # Verify mesh mode
    IFACE_TYPE=$(iw dev "$MESH_IFACE" info 2>/dev/null | grep type | awk '{print $2}')
    if [ "$IFACE_TYPE" != "mesh" ]; then
        echo "[-] Error: $MESH_IFACE is '$IFACE_TYPE' instead of 'mesh'"
        echo "[-] Check if another process is managing this interface"
        exit 1
    fi

    # Join 802.11s mesh
    if [ -n "$MESH_SAE_PASSWORD" ]; then
        echo "[+] Joining encrypted mesh '$MESH_ID' on $FREQ MHz (SAE)..."
        # SAE encryption requires wpa_supplicant — generate config
        WPA_CONF=$(mktemp /tmp/nightwatch-mesh-wpa.XXXXXX)
        chmod 600 "$WPA_CONF"
        cat > "$WPA_CONF" << WPAEOF
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
        wpa_supplicant -B -i "$MESH_IFACE" -c "$WPA_CONF" -D nl80211
        # Clean up WPA config after wpa_supplicant has fully started (contains SAE password)
        # Wait for the wpa_supplicant control socket to confirm it's running
        (
            for _try in $(seq 1 10); do
                if [ -e "/var/run/wpa_supplicant/$MESH_IFACE" ]; then
                    break
                fi
                sleep 1
            done
            rm -f "$WPA_CONF"
        ) &
    else
        echo "[+] Joining open mesh '$MESH_ID' on $FREQ MHz..."
        iw dev "$MESH_IFACE" mesh join "$MESH_ID" freq "$FREQ"
        # Disable HWMP forwarding — batman-adv handles routing
        # (mesh_fwding sysfs may not exist immediately after join)
        { echo 0 > /sys/class/net/"$MESH_IFACE"/mesh/mesh_fwding; } 2>/dev/null || true
    fi

    sleep 1
    echo "[+] 802.11s mesh interface ready"
}

setup_batman() {
    echo "[+] Setting up batman-adv on $BAT_IFACE..."

    # Add mesh interface to batman
    batctl meshif "$BAT_IFACE" if add "$MESH_IFACE" 2>/dev/null || \
        batctl if add "$MESH_IFACE" 2>/dev/null || true

    # Bring up bat0 (no IP here — br0 gets the IP)
    ip link set "$BAT_IFACE" up

    # Enable distributed ARP table for efficiency
    batctl meshif "$BAT_IFACE" dat 1 2>/dev/null || \
        batctl dat 1 2>/dev/null || true

    # Enable bridge loop avoidance (needed when eth0 is bridged)
    batctl meshif "$BAT_IFACE" bla 1 2>/dev/null || \
        batctl bla 1 2>/dev/null || true

    echo "[+] batman-adv $BAT_IFACE is up"
}

setup_client_bridge() {
    echo "[+] Creating Linux bridge $BR_IFACE ($BAT_IFACE + $AP_IFACE)..."

    # batman-adv's "batctl if add" only works for wireless interfaces.
    # For ethernet (eth0 = GL.iNet router), we use a Linux bridge that
    # connects bat0 and eth0 at layer 2. The bridge gets the mesh IP.
    # Note: dhcpcd denyinterfaces is handled by configure_network (setup/firstboot).

    # Release any existing DHCP lease on eth0
    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd --release "$AP_IFACE" 2>/dev/null || true
    fi

    # Remove eth0's default route — it points to the GL.iNet router which has
    # no internet. Without this, it shadows wlan0's route (which has internet)
    # and Docker image pulls, apt, etc. all fail.
    if ip route show default dev "$AP_IFACE" 2>/dev/null | grep -q .; then
        ip route del default dev "$AP_IFACE" 2>/dev/null || true
        echo "[+] Removed default route via $AP_IFACE (no internet on router)"
    fi
    # Make it persistent via NetworkManager
    if command -v nmcli >/dev/null 2>&1; then
        ETH_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep "$AP_IFACE" | head -1 | cut -d: -f1)
        if [ -n "$ETH_CON" ]; then
            nmcli con mod "$ETH_CON" ipv4.never-default yes 2>/dev/null || true
        fi
    fi

    # Remove any existing bridge
    ip link set "$BR_IFACE" down 2>/dev/null || true
    ip link del "$BR_IFACE" 2>/dev/null || true

    # Strip IPs from bridge ports — only the bridge itself gets an IP
    ip addr flush dev "$BAT_IFACE" 2>/dev/null || true
    ip addr flush dev "$AP_IFACE" 2>/dev/null || true

    # Ensure eth0 is up
    ip link set "$AP_IFACE" up 2>/dev/null || true

    # Create bridge and add ports
    ip link add name "$BR_IFACE" type bridge
    if ! ip link set "$BAT_IFACE" master "$BR_IFACE"; then
        echo "[-] Failed to add $BAT_IFACE to bridge $BR_IFACE"
        return 1
    fi
    if ! ip link set "$AP_IFACE" master "$BR_IFACE"; then
        echo "[-] Failed to add $AP_IFACE to bridge $BR_IFACE"
        return 1
    fi

    # Bring up bridge and assign mesh IP
    ip link set "$BR_IFACE" up
    ip addr add "$MESH_IP" dev "$BR_IFACE"

    echo "[+] Bridge $BR_IFACE is up with IP ${MESH_IP%/*}"
    echo "[+] Ports: $BAT_IFACE (mesh) + $AP_IFACE (router)"
}

start_dnsmasq() {
    DNSMASQ_CONF="$PROJECT_DIR/dnsmasq/dnsmasq.conf"
    DNSMASQ_PID="/var/run/dnsmasq-nightwatch.pid"

    # Kill any existing Nightwatch dnsmasq instance
    if [ -f "$DNSMASQ_PID" ]; then
        OLD_PID=$(cat "$DNSMASQ_PID")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            kill "$OLD_PID" 2>/dev/null || true
        fi
        rm -f "$DNSMASQ_PID"
    fi

    # Also stop the system dnsmasq to avoid port conflicts
    systemctl stop dnsmasq 2>/dev/null || true

    if [ -f "$DNSMASQ_CONF" ]; then
        echo "[+] Starting dnsmasq (DHCP + captive portal DNS on $BR_IFACE)..."
        dnsmasq --conf-file="$DNSMASQ_CONF"
        echo "[+] dnsmasq running — WiFi clients will get IPs and captive portal"
    else
        echo "[!] dnsmasq config not found at $DNSMASQ_CONF — run 'make install' to generate"
    fi
}

setup_gateway() {
    if [ "$MESH_GATEWAY" = "true" ]; then
        echo "[+] Configuring this node as a mesh gateway..."
        batctl meshif "$BAT_IFACE" gw_mode server 2>/dev/null || \
            batctl gw_mode server 2>/dev/null || true

        # Enable IP forwarding for internet sharing
        sysctl -w net.ipv4.ip_forward=1 > /dev/null

        # NAT for internet-bound traffic (wlan0 has internet via WiFi client)
        local INET_IFACE="${INET_IFACE:-wlan0}"
        # Only add rules if not already present (prevents duplicates on restart)
        iptables -t nat -C POSTROUTING -o "$INET_IFACE" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -o "$INET_IFACE" -j MASQUERADE 2>/dev/null || true
        iptables -C FORWARD -i "$BR_IFACE" -o "$INET_IFACE" -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -i "$BR_IFACE" -o "$INET_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -i "$INET_IFACE" -o "$BR_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -i "$INET_IFACE" -o "$BR_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

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

        # Wait for mesh interface to be available (USB dongle may take time)
        echo "[+] Waiting for $MESH_IFACE..."
        IFACE_FOUND=false
        for _wait in $(seq 1 30); do
            if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
                echo "[+] $MESH_IFACE is available"
                IFACE_FOUND=true
                break
            fi
            sleep 1
        done

        # If still missing, try USB reset (ath9k_htc firmware may have crashed)
        # Find the device by vendor:product ID since the net/ subdirectory
        # disappears when the driver crashes
        if [ "$IFACE_FOUND" = false ]; then
            echo "[!] $MESH_IFACE not found after 30s — attempting USB reset..."
            USB_RESET_DONE=false
            for dev in /sys/bus/usb/devices/*/idVendor; do
                USB_DEV=$(dirname "$dev")
                if [ "$(cat "$USB_DEV/idVendor" 2>/dev/null)" = "0cf3" ] && \
                   [ "$(cat "$USB_DEV/idProduct" 2>/dev/null)" = "9271" ]; then
                    echo "[+] Found AR9271 at $USB_DEV — resetting..."
                    echo 0 > "$USB_DEV/authorized" 2>/dev/null || true
                    sleep 2
                    echo 1 > "$USB_DEV/authorized" 2>/dev/null || true
                    USB_RESET_DONE=true
                    break
                fi
            done
            if [ "$USB_RESET_DONE" = false ]; then
                echo "[-] AR9271 USB device not found in sysfs"
            fi
            for _wait in $(seq 1 15); do
                if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
                    echo "[+] $MESH_IFACE recovered after USB reset"
                    IFACE_FOUND=true
                    break
                fi
                sleep 1
            done
        fi

        if [ "$IFACE_FOUND" = false ]; then
            echo "[-] Error: $MESH_IFACE not found after USB reset"
            echo "[-] Check that USB WiFi dongle is connected"
            exit 1
        fi

        check_deps iw batctl ip || exit 1

        # Clean up WPA config files on unexpected exit (contain SAE password)
        trap 'rm -f /tmp/nightwatch-mesh-wpa.* 2>/dev/null' EXIT

        load_batman_module
        setup_mesh_interface
        setup_batman
        # Retry bridge setup (eth0 may not be ready immediately after boot)
        for _attempt in 1 2 3; do
            if setup_client_bridge; then
                break
            fi
            if [ "$_attempt" -eq 3 ]; then
                echo "[!] Client bridge setup failed after 3 attempts — mesh still operational"
                break
            fi
            echo "[!] Bridge setup failed (attempt $_attempt/3), retrying in ${_attempt}s..."
            sleep "$_attempt"
        done
        start_dnsmasq
        setup_gateway

        echo ""
        echo "====================================="
        echo "  Mesh network is UP"
        echo "  Mesh IP: ${MESH_IP%/*} (on $BR_IFACE)"
        echo "  Bridge:  $BAT_IFACE + $AP_IFACE → $BR_IFACE"
        echo "====================================="
        ;;

    stop)
        echo "[+] Stopping Nightwatch mesh network..."

        # Stop dnsmasq
        DNSMASQ_PID="/var/run/dnsmasq-nightwatch.pid"
        if [ -f "$DNSMASQ_PID" ]; then
            OLD_PID=$(cat "$DNSMASQ_PID")
            if kill -0 "$OLD_PID" 2>/dev/null; then
                kill "$OLD_PID" 2>/dev/null || true
            fi
            rm -f "$DNSMASQ_PID"
        fi

        # Tear down Linux bridge
        ip link set "$BR_IFACE" down 2>/dev/null || true
        ip link del "$BR_IFACE" 2>/dev/null || true

        # Remove mesh interface from batman
        batctl meshif "$BAT_IFACE" if del "$MESH_IFACE" 2>/dev/null || \
            batctl if del "$MESH_IFACE" 2>/dev/null || true

        # Bring down bat0
        ip link set "$BAT_IFACE" down 2>/dev/null || true

        # Clean up mesh wpa_supplicant (SAE mode only — don't kill internet wpa_supplicant)
        pkill -f "nightwatch-mesh-wpa" 2>/dev/null || true
        rm -f /tmp/nightwatch-mesh-wpa.* 2>/dev/null || true

        # Do NOT bring wlan1 down or leave mesh mode here.
        # The ath9k_htc firmware crashes when wlan1 is cycled down/up,
        # causing it to vanish from the system. Leaving wlan1 in mesh mode
        # is harmless — setup_mesh_interface handles any state on start.

        # NOTE: wlan0 and eth0 are never touched here — wlan0 provides internet,
        # eth0 connects to the external router (both must stay up)

        # Remove only the Nightwatch MASQUERADE rule (preserve Docker/Tailscale NAT)
        INET_IFACE="${INET_IFACE:-wlan0}"
        iptables -t nat -D POSTROUTING -o "$INET_IFACE" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -i "$BR_IFACE" -o "$INET_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "$INET_IFACE" -o "$BR_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

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
        else
            echo "  [!] $BAT_IFACE not found"
        fi

        echo ""
        echo "== Linux Bridge ($BR_IFACE) =="
        if [ -d /sys/class/net/"$BR_IFACE" ]; then
            echo "  IP: $(ip -4 addr show dev "$BR_IFACE" 2>/dev/null | grep inet | awk '{print $2}' || echo 'none')"
            echo "  Ports: $(ls /sys/class/net/"$BR_IFACE"/brif/ 2>/dev/null | tr '\n' ' ' || echo 'none')"
        else
            echo "  [!] $BR_IFACE not found"
        fi

        echo ""
        echo "== dnsmasq (DHCP + captive portal) =="
        DNSMASQ_PID="/var/run/dnsmasq-nightwatch.pid"
        if [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
            echo "  Status: running (PID $(cat "$DNSMASQ_PID"))"
            LEASES="/var/lib/misc/dnsmasq.leases"
            if [ -f "$LEASES" ]; then
                lease_count=$(wc -l < "$LEASES")
                echo "  Active leases: $lease_count"
            fi
        else
            echo "  [!] dnsmasq not running"
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
        echo "== Interfaces in batman-adv =="
        batctl meshif "$BAT_IFACE" if 2>/dev/null || batctl if 2>/dev/null || echo "  (none)"
        ;;

    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
