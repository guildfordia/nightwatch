#!/bin/bash
# Nightwatch — Debug info collector
#
# Generates a JSON file with comprehensive node diagnostics.
# Runs periodically and writes to html/debug.json, served by nginx.
#
# Usage:
#   nightwatch-debug.sh start    # Run as daemon (updates every 15s)
#   nightwatch-debug.sh once     # Generate once and exit
#   nightwatch-debug.sh stop     # Stop daemon

set -euo pipefail

# Read project path
if [ -f /etc/nightwatch.conf ]; then
    # shellcheck source=/dev/null
    source /etc/nightwatch.conf
fi
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-/opt/nightwatch}"

# shellcheck source=common.sh
source "$NIGHTWATCH_DIR/scripts/common.sh"

ENV_FILE="$NIGHTWATCH_DIR/.env"
DEBUG_JSON="$NIGHTWATCH_DIR/html/debug.json"
PID_FILE="/tmp/nightwatch-debug.pid"

if [ -f "$ENV_FILE" ]; then
    load_env "$ENV_FILE"
fi

json_escape() {
    # Escape string for JSON (backslash, quotes, control chars)
    printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")' 2>/dev/null || \
        printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr '\n' '|' | sed 's/|/\\n/g')"
}

collect_debug_info() {
    local NOW
    NOW=$(date +%s)
    local UPTIME
    UPTIME=$(uptime -p 2>/dev/null || uptime | sed 's/.*up/up/')

    # ---- Node identity ----
    local HOSTNAME_VAL
    HOSTNAME_VAL=$(hostname 2>/dev/null || echo "unknown")
    local PI_MODEL
    PI_MODEL=$(cat /proc/device-tree/model 2>/dev/null | tr -d '\0' || echo "unknown")
    local NODE_NUM="${PI_NUMBER:-unknown}"
    local MESH_IP_VAL="${MESH_IP:-unknown}"
    local IS_GW="${MESH_GATEWAY:-false}"
    local MODE="${NODE_MODE:-mesh}"
    # Backward compat: resolve mode from MESH_GATEWAY if NODE_MODE not set
    if [ "$MODE" = "mesh" ] && [ "$IS_GW" = "true" ]; then MODE="gateway"; fi

    # ---- Mesh interface ----
    local MESH_IFACE_VAL="${MESH_IFACE:-wlan1}"
    local MESH_TYPE="down"
    local MESH_CHANNEL=""
    local MESH_SIGNAL=""
    if ip link show "$MESH_IFACE_VAL" >/dev/null 2>&1; then
        MESH_TYPE=$(iw dev "$MESH_IFACE_VAL" info 2>/dev/null | grep -oP 'type \K\S+' || echo "unknown")
        MESH_CHANNEL=$(iw dev "$MESH_IFACE_VAL" info 2>/dev/null | grep -oP 'channel \K[0-9]+' || echo "")
    fi

    # ---- Batman-adv ----
    local BAT_VERSION=""
    local BAT_GW_MODE=""
    local BAT_ALGO=""
    local NEIGHBORS_JSON="[]"
    local ORIGINATORS_JSON="[]"
    local NEIGHBOR_COUNT=0

    if [ -d /sys/class/net/bat0 ]; then
        BAT_VERSION=$(cat /sys/module/batman_adv/version 2>/dev/null || echo "unknown")
        BAT_GW_MODE=$(batctl meshif bat0 gw_mode 2>/dev/null || echo "unknown")
        BAT_ALGO=$(batctl meshif bat0 ra 2>/dev/null || echo "unknown")

        # Neighbors
        local NEIGHBOR_LINES
        NEIGHBOR_LINES=$(batctl meshif bat0 n 2>/dev/null | tail -n +3 || true)
        NEIGHBOR_COUNT=$(echo "$NEIGHBOR_LINES" | grep -c . 2>/dev/null || echo "0")
        NEIGHBOR_COUNT=${NEIGHBOR_COUNT:-0}

        NEIGHBORS_JSON="["
        local FIRST=true
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local MAC=$(echo "$line" | awk '{print $2}')
            local IFACE=$(echo "$line" | awk '{print $NF}')
            local LAST_SEEN=$(echo "$line" | awk '{print $1}')
            if [ "$FIRST" = true ]; then FIRST=false; else NEIGHBORS_JSON+=","; fi
            NEIGHBORS_JSON+="{\"mac\":\"$MAC\",\"interface\":\"$IFACE\",\"last_seen\":\"$LAST_SEEN\"}"
        done <<< "$NEIGHBOR_LINES"
        NEIGHBORS_JSON+="]"

        # Originators (full mesh topology)
        local ORIG_LINES
        ORIG_LINES=$(batctl meshif bat0 o 2>/dev/null | tail -n +3 | head -20 || true)
        ORIGINATORS_JSON="["
        FIRST=true
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            # Format: originator last-seen (#/255) Nexthop [outgoingIface]
            local ORIG=$(echo "$line" | awk '{print $1}')
            local LAST=$(echo "$line" | awk '{print $2}')
            local TQ=$(echo "$line" | grep -oP '\(\s*\K[0-9]+' || echo "0")
            local NEXTHOP=$(echo "$line" | awk '{for(i=1;i<=NF;i++){if($i~"^[0-9a-f][0-9a-f]:" && i>3){print $i;break}}}')
            if [ "$FIRST" = true ]; then FIRST=false; else ORIGINATORS_JSON+=","; fi
            ORIGINATORS_JSON+="{\"originator\":\"$ORIG\",\"last_seen\":\"$LAST\",\"tq\":$TQ,\"nexthop\":\"$NEXTHOP\"}"
        done <<< "$ORIG_LINES"
        ORIGINATORS_JSON+="]"
    fi

    # ---- Bridge ----
    local BR_STATUS="down"
    local BR_IP=""
    local BR_PORTS=""
    if [ -d /sys/class/net/br0 ]; then
        BR_STATUS="up"
        BR_IP=$(ip -4 addr show dev br0 2>/dev/null | grep -oP 'inet \K[^ ]+' || echo "none")
        BR_PORTS=$(ls /sys/class/net/br0/brif/ 2>/dev/null | tr '\n' ',' | sed 's/,$//' || echo "none")
    fi

    # ---- Discovery peers ----
    local PEERS_JSON="[]"
    local PEER_FILE="/tmp/nightwatch-peers"
    if [ -f "$PEER_FILE" ] && [ -s "$PEER_FILE" ]; then
        PEERS_JSON="["
        local FIRST=true
        while IFS='|' read -r num ip name ts; do
            [ -z "$num" ] && continue
            local AGE=$((NOW - ts))
            if [ "$FIRST" = true ]; then FIRST=false; else PEERS_JSON+=","; fi
            PEERS_JSON+="{\"node\":$num,\"ip\":\"$ip\",\"name\":\"$name\",\"age_seconds\":$AGE}"
        done < "$PEER_FILE"
        PEERS_JSON+="]"
    fi

    # ---- App services ----
    local SERVICES_JSON="["
    local FIRST=true
    for svc_name in ngircd nightwatch-bridge nginx; do
        local SVC_STATE
        SVC_STATE=$(systemctl is-active "$svc_name" 2>/dev/null || echo "unknown")
        local SVC_SUB
        SVC_SUB=$(systemctl show -p SubState --value "$svc_name" 2>/dev/null || echo "unknown")
        local SVC_STARTED
        SVC_STARTED=$(systemctl show -p ActiveEnterTimestamp --value "$svc_name" 2>/dev/null || echo "")
        if [ "$FIRST" = true ]; then FIRST=false; else SERVICES_JSON+=","; fi
        SERVICES_JSON+="{\"name\":\"$svc_name\",\"active\":\"$SVC_STATE\",\"sub\":\"$SVC_SUB\",\"started\":\"$SVC_STARTED\"}"
    done
    SERVICES_JSON+="]"

    # ---- Systemd services ----
    local SYSTEMD_JSON="["
    local FIRST=true
    for svc in nightwatch-mesh nightwatch-docker nightwatch-discovery nightwatch-nodeconfig nightwatch-led nightwatch-watchdog; do
        local STATE
        STATE=$(systemctl show -p ActiveState --value "$svc" 2>/dev/null || echo "unknown")
        local SUB
        SUB=$(systemctl show -p SubState --value "$svc" 2>/dev/null || echo "unknown")
        if [ "$FIRST" = true ]; then FIRST=false; else SYSTEMD_JSON+=","; fi
        SYSTEMD_JSON+="{\"name\":\"$svc\",\"active\":\"$STATE\",\"sub\":\"$SUB\"}"
    done
    SYSTEMD_JSON+="]"

    # ---- Mesh peers (802.11s station dump) ----
    local STATIONS_JSON="[]"
    if iw dev "$MESH_IFACE_VAL" info 2>/dev/null | grep -q mesh; then
        STATIONS_JSON="["
        local FIRST=true
        local CUR_MAC=""
        local CUR_SIGNAL=""
        local CUR_PLINK=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^Station ]]; then
                if [ -n "$CUR_MAC" ]; then
                    if [ "$FIRST" = true ]; then FIRST=false; else STATIONS_JSON+=","; fi
                    STATIONS_JSON+="{\"mac\":\"$CUR_MAC\",\"signal\":\"$CUR_SIGNAL\",\"plink\":\"$CUR_PLINK\"}"
                fi
                CUR_MAC=$(echo "$line" | awk '{print $2}')
                CUR_SIGNAL=""
                CUR_PLINK=""
            elif [[ "$line" =~ signal: ]]; then
                CUR_SIGNAL=$(echo "$line" | grep -oP 'signal:\s*\K[-0-9]+' || echo "")
            elif [[ "$line" =~ "mesh plink:" ]]; then
                CUR_PLINK=$(echo "$line" | grep -oP 'mesh plink:\s*\K\S+' || echo "")
            fi
        done <<< "$(iw dev "$MESH_IFACE_VAL" station dump 2>/dev/null || true)"
        # Flush last station
        if [ -n "$CUR_MAC" ]; then
            if [ "$FIRST" = true ]; then FIRST=false; else STATIONS_JSON+=","; fi
            STATIONS_JSON+="{\"mac\":\"$CUR_MAC\",\"signal\":\"$CUR_SIGNAL\",\"plink\":\"$CUR_PLINK\"}"
        fi
        STATIONS_JSON+="]"
    fi

    # ---- Conflict check ----
    local CONFLICT=""
    if [ -f /tmp/nightwatch-conflict ]; then
        CONFLICT=$(cat /tmp/nightwatch-conflict 2>/dev/null || echo "")
    fi

    # ---- System resources ----
    local MEM_TOTAL MEM_AVAIL CPU_TEMP DISK_USAGE
    MEM_TOTAL=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}' || echo "0")
    MEM_AVAIL=$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{printf "%.0f", $2/1024}' || echo "0")
    CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | awk '{printf "%.1f", $1/1000}' || echo "0")
    DISK_USAGE=$(df / 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%' || echo "0")

    # ---- Write JSON (atomic: write to tmp + mv) ----
    local TMP_JSON="${DEBUG_JSON}.tmp.$$"
    cat > "$TMP_JSON" << JSONEOF
{
  "timestamp": $NOW,
  "collected_at": "$(date -Iseconds)",
  "node": {
    "number": $NODE_NUM,
    "hostname": "$HOSTNAME_VAL",
    "model": "$PI_MODEL",
    "mesh_ip": "$MESH_IP_VAL",
    "mode": "$MODE",
    "gateway": $IS_GW,
    "uptime": "$UPTIME"
  },
  "system": {
    "memory_total_mb": $MEM_TOTAL,
    "memory_available_mb": $MEM_AVAIL,
    "cpu_temp_c": $CPU_TEMP,
    "disk_usage_pct": $DISK_USAGE
  },
  "mesh": {
    "interface": "$MESH_IFACE_VAL",
    "type": "$MESH_TYPE",
    "channel": "$MESH_CHANNEL",
    "stations": $STATIONS_JSON
  },
  "batman": {
    "version": "$BAT_VERSION",
    "algorithm": "$BAT_ALGO",
    "gateway_mode": "$BAT_GW_MODE",
    "neighbor_count": $NEIGHBOR_COUNT,
    "neighbors": $NEIGHBORS_JSON,
    "originators": $ORIGINATORS_JSON
  },
  "bridge": {
    "status": "$BR_STATUS",
    "ip": "$BR_IP",
    "ports": "$BR_PORTS"
  },
  "discovery": {
    "peers": $PEERS_JSON
  },
  "services": $SERVICES_JSON,
  "systemd": $SYSTEMD_JSON,
  "conflict": "$CONFLICT"
}
JSONEOF
    mv "$TMP_JSON" "$DEBUG_JSON"
}

case "${1:-once}" in
    start)
        echo "[+] Debug info collector starting (every 15s)"
        echo $$ > "$PID_FILE"
        trap 'rm -f "$PID_FILE"; exit 0' SIGTERM SIGINT EXIT
        while true; do
            collect_debug_info 2>/dev/null || true
            sleep 15
        done
        ;;
    once)
        collect_debug_info
        echo "[+] Debug info written to $DEBUG_JSON"
        ;;
    stop)
        if [ -f "$PID_FILE" ]; then
            kill "$(cat "$PID_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE"
            echo "[+] Debug collector stopped"
        fi
        ;;
    *)
        echo "Usage: $0 {start|once|stop}"
        exit 1
        ;;
esac
