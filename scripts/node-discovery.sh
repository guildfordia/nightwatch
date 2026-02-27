#!/bin/bash
# Nightwatch — Node discovery daemon
#
# Broadcasts this node's identity on the mesh via UDP and listens for others.
# When the peer list changes, regenerates ngircd.conf and reloads ngircd.
#
# Protocol:
#   UDP broadcast on port 4919 over bat0, every BEACON_INTERVAL seconds
#   Payload: NIGHTWATCH|<node_num>|<mesh_ip>|<server_name>|<timestamp>
#
# Peer file: /tmp/nightwatch-peers (one line per peer, same format)
# Peers expire after PEER_TIMEOUT seconds of no beacon.
#
# Network: 192.168.199.101-120 (max 20 nodes)
#
# Usage:
#   scripts/node-discovery.sh start    # Run as daemon (called by systemd)
#   scripts/node-discovery.sh peers    # Show current peer list
#   scripts/node-discovery.sh stop     # Stop daemon

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

load_env "$ENV_FILE"

# Config
BAT_IFACE="${BAT_IFACE:-bat0}"
DISCOVERY_PORT=4919
BEACON_INTERVAL=30
PEER_TIMEOUT=90
PEER_FILE="/tmp/nightwatch-peers"
PID_FILE="/tmp/nightwatch-discovery.pid"
LOCAL_IP="${MESH_IP%/*}"
NODE_NUM="${PI_NUMBER:-1}"
SERVER_NAME="node${NODE_NUM}.nightwatch.irc"
IRC_LINK_PASSWORD="${IRC_LINK_PASSWORD:-nightwatch-mesh-link}"
BROADCAST_IP="192.168.199.255"

detect_docker_compose

CONFLICT_FILE="/tmp/nightwatch-conflict"

log() { echo "[discovery] $(date '+%H:%M:%S') $1"; }

# Note: IP conflict detection is done via beacon monitoring, not ARP.
# When a beacon arrives with our own node number from a different IP,
# we log a conflict to /tmp/nightwatch-conflict.

# ---- Beacon sender (runs in background) ----
send_beacons() {
    while true; do
        PAYLOAD="NIGHTWATCH|${NODE_NUM}|${LOCAL_IP}|${SERVER_NAME}|$(date +%s)"
        # Send UDP broadcast on bat0
        echo "$PAYLOAD" | socat - UDP4-DATAGRAM:${BROADCAST_IP}:${DISCOVERY_PORT},broadcast,interface=${BAT_IFACE} 2>/dev/null || \
            echo "$PAYLOAD" > /dev/udp/${BROADCAST_IP}/${DISCOVERY_PORT} 2>/dev/null || true
        sleep "$BEACON_INTERVAL"
    done
}

# ---- Beacon receiver ----
receive_beacons() {
    # Listen for UDP broadcasts
    socat -u UDP4-RECVFROM:${DISCOVERY_PORT},broadcast,reuseaddr,fork STDOUT 2>/dev/null | while IFS= read -r line; do
        # Parse: NIGHTWATCH|<node_num>|<mesh_ip>|<server_name>|<timestamp>
        if [[ "$line" =~ ^NIGHTWATCH\| ]]; then
            PEER_NUM=$(echo "$line" | cut -d'|' -f2)
            PEER_IP=$(echo "$line" | cut -d'|' -f3)
            PEER_NAME=$(echo "$line" | cut -d'|' -f4)
            NOW=$(date +%s)

            # Conflict detection: same node number from a different IP
            if [ "$PEER_NUM" = "$NODE_NUM" ]; then
                if [ "$PEER_IP" != "$LOCAL_IP" ]; then
                    log "CONFLICT: node $PEER_NUM seen from $PEER_IP (we are also node $NODE_NUM at $LOCAL_IP)!"
                    echo "Node conflict: node $PEER_NUM exists at both $LOCAL_IP and $PEER_IP" > "$CONFLICT_FILE"
                fi
                continue
            fi

            # Update peer file with flock to prevent concurrent write races
            (
                flock -x 200
                touch "$PEER_FILE"
                # Remove old entry for this peer, add fresh one
                grep -v "^${PEER_NUM}|" "$PEER_FILE" 2>/dev/null > "${PEER_FILE}.tmp" || true
                echo "${PEER_NUM}|${PEER_IP}|${PEER_NAME}|${NOW}" >> "${PEER_FILE}.tmp"
                mv "${PEER_FILE}.tmp" "$PEER_FILE"
            ) 200>"${PEER_FILE}.lock"

            log "Beacon from node $PEER_NUM ($PEER_NAME @ $PEER_IP)"

            # Check if ngircd config needs updating
            update_irc_config
        fi
    done
}

# ---- Expire stale peers ----
expire_peers() {
    while true; do
        sleep "$PEER_TIMEOUT"
        if [ ! -f "$PEER_FILE" ]; then
            continue
        fi

        NOW=$(date +%s)
        CHANGED=false
        while IFS='|' read -r num ip name ts; do
            AGE=$((NOW - ts))
            if [ "$AGE" -gt "$PEER_TIMEOUT" ]; then
                log "Peer node $num ($name) expired (${AGE}s since last beacon)"
                CHANGED=true
            fi
        done < "$PEER_FILE"

        if [ "$CHANGED" = true ]; then
            # Remove expired entries with flock to prevent concurrent write races
            (
                flock -x 200
                CUTOFF=$((NOW - PEER_TIMEOUT))
                awk -F'|' -v cutoff="$CUTOFF" '$4 >= cutoff' "$PEER_FILE" > "${PEER_FILE}.tmp" 2>/dev/null || true
                mv "${PEER_FILE}.tmp" "$PEER_FILE"
            ) 200>"${PEER_FILE}.lock"
            update_irc_config
        fi
    done
}

# ---- Generate ngircd.conf from current peers ----
generate_irc_config() {
    local CONF="$PROJECT_DIR/ngircd/ngircd.conf"

    generate_ngircd_base_conf "$CONF" "$SERVER_NAME" "$NODE_NUM"

    # Add server links for each known peer
    if [ -f "$PEER_FILE" ]; then
        while IFS='|' read -r num ip name ts; do
            [ -z "$num" ] && continue
            cat >> "$CONF" << EOF

[Server]
Name = $name
Host = $ip
Port = 6667
MyPassword = $IRC_LINK_PASSWORD
PeerPassword = $IRC_LINK_PASSWORD
Group = 1
Passive = no
EOF
        done < "$PEER_FILE"
    fi
}

# ---- Update IRC config if peer list changed ----
LAST_PEER_HASH=""
update_irc_config() {
    # Hash current peer file to detect changes
    CURRENT_HASH=$(sort "$PEER_FILE" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1 || echo "")
    if [ "$CURRENT_HASH" = "$LAST_PEER_HASH" ]; then
        return
    fi
    LAST_PEER_HASH="$CURRENT_HASH"

    PEER_COUNT=$(wc -l < "$PEER_FILE" 2>/dev/null || echo "0")
    log "Peer list changed ($PEER_COUNT peers) — regenerating ngircd.conf"

    generate_irc_config

    # Reload ngircd config inside the container
    # Send SIGHUP directly to the ngircd process (not PID 1 which is s6-init)
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q ngircd; then
        # Try sending HUP to ngircd process directly
        if docker exec ngircd pkill -HUP ngircd 2>/dev/null; then
            log "Sent HUP to ngircd process (config reload)"
        else
            # Fallback: restart container
            docker restart ngircd 2>/dev/null || true
            log "Restarted ngircd (config reload)"
        fi
    fi
}

# ---- Commands ----

case "${1:-start}" in
    start)
        log "Starting discovery daemon for node $NODE_NUM ($SERVER_NAME @ $LOCAL_IP)"
        log "Broadcast: ${BROADCAST_IP}:${DISCOVERY_PORT} on $BAT_IFACE"
        log "Beacon interval: ${BEACON_INTERVAL}s, peer timeout: ${PEER_TIMEOUT}s"

        # Check for socat
        if ! command -v socat >/dev/null 2>&1; then
            log "ERROR: socat not installed. Run: sudo apt-get install -y socat"
            exit 1
        fi

        # Clean conflict/peer files
        rm -f "$CONFLICT_FILE"
        > "$PEER_FILE"

        # Generate initial config (no peers yet)
        generate_irc_config
        log "Initial ngircd.conf generated (no peers yet)"

        # Save PID
        echo $$ > "$PID_FILE"

        # Start beacon sender in background
        send_beacons &
        SENDER_PID=$!

        # Start peer expiry checker in background
        expire_peers &
        EXPIRY_PID=$!

        # Handle cleanup on exit
        trap 'log "Stopping..."; kill $SENDER_PID $EXPIRY_PID 2>/dev/null; rm -f "$PID_FILE"; exit 0' SIGTERM SIGINT EXIT

        # Receive beacons (blocking — this is the main loop)
        receive_beacons
        ;;

    stop)
        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE")
            if kill -0 "$PID" 2>/dev/null; then
                kill "$PID" 2>/dev/null || true
                log "Stopped (PID $PID)"
            else
                log "Stale PID file (process $PID not running)"
            fi
            rm -f "$PID_FILE"
        else
            log "Not running"
        fi
        ;;

    peers)
        # Show conflicts if any
        if [ -f "$CONFLICT_FILE" ]; then
            echo -e "\033[0;31m[CONFLICT] $(cat "$CONFLICT_FILE")\033[0m"
            echo ""
        fi
        if [ ! -f "$PEER_FILE" ] || [ ! -s "$PEER_FILE" ]; then
            echo "No peers discovered yet"
            exit 0
        fi
        NOW=$(date +%s)
        echo "Discovered peers:"
        while IFS='|' read -r num ip name ts; do
            AGE=$((NOW - ts))
            echo "  Node $num: $name @ $ip (${AGE}s ago)"
        done < "$PEER_FILE"
        ;;

    *)
        echo "Usage: $0 {start|stop|peers}"
        exit 1
        ;;
esac
