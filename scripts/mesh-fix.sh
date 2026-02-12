#!/bin/bash
# Mesh setup script for IBSS with optional static ARP
# Reads configuration from .env and optional arp-entries.conf

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"
ARP_CONF="$PROJECT_DIR/arp-entries.conf"

# Load .env
if [ ! -f "$ENV_FILE" ]; then
    echo "[-] Error: $ENV_FILE not found. Run 'make prepare-env' first."
    exit 1
fi
set -o allexport
source "$ENV_FILE"
set +o allexport

IFACE="${IFACE:-wlan1}"
MESH_ID="${MESH_ID:-batmesh}"
FREQ="${FREQ:-2412}"

if [ -z "$MESH_IP" ]; then
    echo "[-] Error: MESH_IP not set in $ENV_FILE"
    exit 1
fi

# Ensure CIDR notation
if [[ "$MESH_IP" != *"/"* ]]; then
    MESH_IP="${MESH_IP}/24"
fi

# Load ARP entries from config file if it exists
# Format: one "IP MAC" pair per line, e.g.:
#   192.168.199.102 90:de:80:cc:24:98
#   192.168.199.103 90:de:80:c7:7d:4c
load_arp_entries() {
    ARP_ENTRIES=()
    if [ -f "$ARP_CONF" ]; then
        while IFS= read -r line; do
            # Skip comments and blank lines
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            ARP_ENTRIES+=("$line")
        done < "$ARP_CONF"
        echo "[+] Loaded ${#ARP_ENTRIES[@]} ARP entries from $ARP_CONF"
    else
        echo "[*] No $ARP_CONF found — skipping static ARP (will rely on ARP discovery)"
    fi
}

case "$1" in
    start)
        echo "[+] Starting mesh network on $IFACE..."

        # 1. Bring down interface first
        ip link set "$IFACE" down

        # 2. Set IBSS mode
        iw dev "$IFACE" set type ibss

        # 3. Bring up interface
        ip link set "$IFACE" up

        # 4. Wait for interface to be ready
        sleep 2

        # 5. Join IBSS network
        iw dev "$IFACE" ibss join "$MESH_ID" "$FREQ" fixed-freq 02:12:34:56:78:9A

        # 6. Wait for IBSS to establish
        sleep 2

        # 7. Add IP address
        ip addr flush dev "$IFACE"
        ip addr add "$MESH_IP" dev "$IFACE"

        # 8. Add static ARP entries if configured
        load_arp_entries
        for entry in "${ARP_ENTRIES[@]}"; do
            read -r arp_ip arp_mac <<< "$entry"
            echo "    Adding ARP: $arp_ip -> $arp_mac"
            arp -s "$arp_ip" "$arp_mac" || echo "    Warning: Failed to add ARP entry for $arp_ip"
        done

        echo "[+] Mesh network started on $IFACE with IP ${MESH_IP%/*}"
        ;;

    stop)
        echo "[+] Stopping mesh network on $IFACE..."
        iw dev "$IFACE" ibss leave 2>/dev/null || true
        ip addr flush dev "$IFACE" 2>/dev/null || true
        ip link set "$IFACE" down 2>/dev/null || true
        echo "[+] Mesh network stopped"
        ;;

    status)
        echo "=== Interface Status ==="
        ip addr show "$IFACE" 2>/dev/null || echo "[!] $IFACE not found"
        echo ""
        echo "=== IBSS Status ==="
        iw dev "$IFACE" info 2>/dev/null || echo "[!] Not in IBSS mode"
        echo ""
        echo "=== IBSS Stations ==="
        iw dev "$IFACE" station dump 2>/dev/null || echo "[!] No stations"
        echo ""
        echo "=== ARP Table ==="
        arp -n 2>/dev/null | grep "192.168.199" || echo "[!] No ARP entries"
        ;;

    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
