#!/bin/bash
# Nightwatch — Show detailed node info
#
# Displays identity, system stats, network, mesh, and service status.
# Used by: make info

set -euo pipefail

BOLD='\033[1m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

section() { echo -e "\n${BOLD}${CYAN}== $1 ==${NC}"; }

# ---- Load env ----
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ENV_FILE="$NIGHTWATCH_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$ENV_FILE"; set +a
fi

# ---- Identity ----
section "Node Identity"
echo "  Hostname:    $(hostname 2>/dev/null || echo unknown)"
echo "  Pi model:    $(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo unknown)"
echo "  Node number: ${PI_NUMBER:-unknown}"
echo "  Mesh IP:     ${MESH_IP:-unknown}"
echo "  Gateway:     ${MESH_GATEWAY:-false}"

# ---- System ----
section "System"
echo "  Uptime:      $(uptime -p 2>/dev/null || uptime | sed 's/.*up/up/')"
MEM_TOTAL=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}' || echo "?")
MEM_AVAIL=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}' || echo "?")
echo "  Memory:      ${MEM_AVAIL}MB available / ${MEM_TOTAL}MB total"
TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}' || echo "?")
echo "  CPU temp:    ${TEMP}C"
echo "  Disk:        $(df -h / 2>/dev/null | tail -1 | awk '{print $3 " used / " $2 " (" $5 ")"}')"

# ---- Network interfaces ----
section "Network Interfaces"
for iface in br0 bat0 ${MESH_IFACE:-wlan1} eth0 wlan0; do
    if [ -d "/sys/class/net/$iface" ]; then
        IP=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[^ ]+' || echo "no IP")
        STATE=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        echo "  $iface: $IP ($STATE)"
    fi
done

# ---- Mesh ----
section "Mesh (802.11s + batman-adv)"
MESH_IF="${MESH_IFACE:-wlan1}"
if [ -d "/sys/class/net/$MESH_IF" ]; then
    TYPE=$(iw dev "$MESH_IF" info 2>/dev/null | grep -oP 'type \K\S+' || echo "unknown")
    CHAN=$(iw dev "$MESH_IF" info 2>/dev/null | grep -oP 'channel \K[0-9]+' || echo "?")
    echo "  Interface: $MESH_IF (type: $TYPE, channel: $CHAN)"
else
    echo -e "  ${RED}$MESH_IF not found${NC}"
fi

if [ -d /sys/class/net/bat0 ]; then
    echo "  Batman:    v$(cat /sys/module/batman_adv/version 2>/dev/null || echo '?')"
    echo "  GW mode:   $(batctl meshif bat0 gw_mode 2>/dev/null || echo unknown)"

    echo "  Neighbors:"
    batctl meshif bat0 n 2>/dev/null | tail -n +3 | while IFS= read -r line; do
        [ -z "$line" ] && continue
        echo "    $line"
    done
    if ! batctl meshif bat0 n 2>/dev/null | tail -n +3 | grep -q .; then
        echo "    (none)"
    fi

    echo "  802.11s stations:"
    iw dev "$MESH_IF" station dump 2>/dev/null | grep -E '^Station|signal:|mesh plink:' | while IFS= read -r line; do
        echo "    $line"
    done
    if ! iw dev "$MESH_IF" station dump 2>/dev/null | grep -q '^Station'; then
        echo "    (none)"
    fi
else
    echo -e "  ${RED}bat0 not found — batman-adv not loaded${NC}"
fi

# ---- Discovery peers ----
section "Discovery Peers"
PEER_FILE="/tmp/nightwatch-peers"
if [ -f "$PEER_FILE" ] && [ -s "$PEER_FILE" ]; then
    NOW=$(date +%s)
    while IFS='|' read -r num ip name ts; do
        [ -z "$num" ] && continue
        AGE=$((NOW - ts))
        echo "  Node $num: $ip ($name) — ${AGE}s ago"
    done < "$PEER_FILE"
else
    echo "  (no peers discovered)"
fi

# ---- App services ----
section "App Services"
for svc in ngircd nightwatch-bridge nginx; do
    STATE=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    case "$STATE" in
        active)   COLOR="$GREEN" ;;
        failed)   COLOR="$RED" ;;
        inactive) COLOR="$YELLOW" ;;
        *)        COLOR="$NC" ;;
    esac
    echo -e "  ${COLOR}$svc: $STATE${NC}"
done

# ---- Systemd services ----
section "Systemd Services"
for svc in nightwatch-mesh nightwatch-docker nightwatch-discovery nightwatch-nodeconfig nightwatch-led nightwatch-bridge nightwatch-debug; do
    STATE=$(systemctl is-active "$svc" 2>/dev/null || echo "unknown")
    case "$STATE" in
        active)   COLOR="$GREEN" ;;
        failed)   COLOR="$RED" ;;
        inactive) COLOR="$YELLOW" ;;
        *)        COLOR="$NC" ;;
    esac
    echo -e "  ${COLOR}$svc: $STATE${NC}"
done

# ---- Connectivity ----
section "Connectivity"
echo -n "  Mesh peers: "
for i in $(seq 1 20); do
    ip="192.168.199.$((100 + i))"
    LOCAL="${MESH_IP%%/*}"
    [ "$ip" = "$LOCAL" ] && continue
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        RTT=$(ping -c 1 -W 1 "$ip" 2>/dev/null | grep 'time=' | sed 's/.*time=//' || echo "?")
        echo -n "$ip($RTT) "
    fi
done
echo ""

if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo -e "  Internet:   ${GREEN}reachable${NC}"
else
    echo -e "  Internet:   ${YELLOW}not reachable${NC} (expected unless gateway)"
fi

# ---- Tailscale ----
if command -v tailscale >/dev/null 2>&1; then
    section "Tailscale"
    tailscale status 2>/dev/null | head -5 || echo "  (not connected)"
fi

echo ""
