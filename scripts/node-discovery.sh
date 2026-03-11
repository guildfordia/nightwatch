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
DISCOVERY_PORT="${DISCOVERY_PORT:-4919}"
BEACON_INTERVAL="${BEACON_INTERVAL:-30}"
PEER_TIMEOUT="${PEER_TIMEOUT:-90}"
PEER_FILE="/tmp/nightwatch-peers"
PID_FILE="/tmp/nightwatch-discovery.pid"
LOCAL_IP="${MESH_IP%/*}"
NODE_NUM="${PI_NUMBER:-1}"
SERVER_NAME="node${NODE_NUM}.nightwatch.irc"
IRC_LINK_PASSWORD="${IRC_LINK_PASSWORD:-nightwatch-mesh-link}"
BROADCAST_IP="192.168.199.255"

CONFLICT_FILE="/tmp/nightwatch-conflict"

log() { echo "[discovery] $(date '+%H:%M:%S') $1"; }

# Note: IP conflict detection is done via beacon monitoring, not ARP.
# When a beacon arrives with our own node number from a different IP,
# we log a conflict to /tmp/nightwatch-conflict.

# ---- Beacon sender (runs in background) ----
send_beacons() {
    while true; do
        PAYLOAD="NIGHTWATCH|${NODE_NUM}|${LOCAL_IP}|${SERVER_NAME}|$(date +%s)"
        # Send on br0 (where MESH_IP lives) — bat0 is a virtual L2 interface with
        # no IP, so interface=bat0 can fail. Fall back to bat0 then /dev/udp.
        echo "$PAYLOAD" | socat - UDP4-DATAGRAM:${BROADCAST_IP}:${DISCOVERY_PORT},broadcast,interface=br0 2>/dev/null || \
            echo "$PAYLOAD" | socat - UDP4-DATAGRAM:${BROADCAST_IP}:${DISCOVERY_PORT},broadcast,interface=${BAT_IFACE} 2>/dev/null || \
            echo "$PAYLOAD" > /dev/udp/${BROADCAST_IP}/${DISCOVERY_PORT} 2>/dev/null || true
        sleep "$BEACON_INTERVAL"
    done
}

# ---- Beacon receiver ----
receive_beacons() {
    # Listen for UDP broadcasts
    # Use process substitution (not pipe) so the while loop runs in the main
    # shell process and variables (like LAST_PEER_HASH) persist across iterations.
    while IFS= read -r line; do
        # Parse: NIGHTWATCH|<node_num>|<mesh_ip>|<server_name>|<timestamp>
        if [[ "$line" =~ ^NIGHTWATCH\| ]]; then
            PEER_NUM=$(echo "$line" | cut -d'|' -f2)
            PEER_IP=$(echo "$line" | cut -d'|' -f3)
            PEER_NAME=$(echo "$line" | cut -d'|' -f4)
            NOW=$(date +%s)

            # Validate beacon fields to prevent injection
            if ! [[ "$PEER_NUM" =~ ^[0-9]+$ ]] || ! [[ "$PEER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! [[ "$PEER_NAME" =~ ^[a-zA-Z0-9._-]+$ ]]; then
                log "WARNING: Invalid beacon ignored: $line"
                continue
            fi

            # Conflict detection: same node number from a different IP
            if [ "$PEER_NUM" = "$NODE_NUM" ]; then
                if [ "$PEER_IP" != "$LOCAL_IP" ]; then
                    log "CONFLICT: node $PEER_NUM seen from $PEER_IP (we are also node $NODE_NUM at $LOCAL_IP)!"
                    echo "Node conflict: node $PEER_NUM exists at both $LOCAL_IP and $PEER_IP" > "$CONFLICT_FILE"
                    # Auto-resolve: trigger nodeconfig to reassign our number
                    if [ -x "$PROJECT_DIR/scripts/nodeconfig.sh" ]; then
                        log "Triggering nodeconfig for conflict resolution..."
                        systemctl restart nightwatch-nodeconfig.service 2>/dev/null || \
                            "$PROJECT_DIR/scripts/nodeconfig.sh" 2>/dev/null || true
                    fi
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
    done < <(socat -u UDP4-RECV:${DISCOVERY_PORT},reuseaddr STDOUT 2>/dev/null)
}

# ---- Expire stale peers ----
expire_peers() {
    while true; do
        sleep "$PEER_TIMEOUT"
        if [ ! -f "$PEER_FILE" ]; then
            continue
        fi

        # Perform entire read+check+write under flock to prevent races
        (
            flock -x 200
            NOW=$(date +%s)
            CUTOFF=$((NOW - PEER_TIMEOUT))

            # Log expired peers
            while IFS='|' read -r num ip name ts; do
                [ -z "$num" ] && continue
                AGE=$((NOW - ts))
                if [ "$AGE" -gt "$PEER_TIMEOUT" ]; then
                    log "Peer node $num ($name) expired (${AGE}s since last beacon)"
                fi
            done < "$PEER_FILE"

            # Remove expired entries
            BEFORE=$(wc -l < "$PEER_FILE" 2>/dev/null || echo "0")
            awk -F'|' -v cutoff="$CUTOFF" '$4 >= cutoff' "$PEER_FILE" > "${PEER_FILE}.tmp" 2>/dev/null || true
            mv "${PEER_FILE}.tmp" "$PEER_FILE"
            AFTER=$(wc -l < "$PEER_FILE" 2>/dev/null || echo "0")

            if [ "$BEFORE" != "$AFTER" ]; then
                # Signal parent that peers changed (via temp file)
                touch "${PEER_FILE}.changed"
            fi
        ) 200>"${PEER_FILE}.lock"

        if [ -f "${PEER_FILE}.changed" ]; then
            rm -f "${PEER_FILE}.changed"
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
LAST_PEER_COUNT=0
update_irc_config() {
    # Hash current peer file to detect changes (exclude timestamp field
    # so that beacon refreshes don't trigger unnecessary restarts)
    CURRENT_HASH=$(sort "$PEER_FILE" 2>/dev/null | cut -d'|' -f1-3 | cksum || echo "")
    if [ "$CURRENT_HASH" = "$LAST_PEER_HASH" ]; then
        return
    fi

    PEER_COUNT=$(wc -l < "$PEER_FILE" 2>/dev/null || echo "0")
    PEER_COUNT=$((PEER_COUNT + 0))
    local PREV_COUNT=$LAST_PEER_COUNT

    LAST_PEER_HASH="$CURRENT_HASH"
    LAST_PEER_COUNT=$PEER_COUNT

    log "Peer list changed ($PEER_COUNT peers) — regenerating ngircd.conf"

    generate_irc_config

    # Only restart ngircd when peers are ADDED (new [Server] blocks need a
    # full restart). When peers are removed, just regenerate the config —
    # ngircd will stop retrying the dead peer on its own, and restarting
    # would kill all active client connections for no benefit.
    if [ "$PEER_COUNT" -gt "$PREV_COUNT" ]; then
        if systemctl is-active --quiet ngircd 2>/dev/null; then
            systemctl restart ngircd 2>/dev/null || true
            log "Restarted ngircd (new peer added)"
        fi
    else
        log "Peers removed — config updated, skipping ngircd restart (connections preserved)"
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

        # Handle cleanup on exit (guard prevents double-fire: SIGTERM calls
        # exit 0, which triggers EXIT trap again → bash pop_var_context crash)
        _cleanup_done=false
        cleanup() {
            $_cleanup_done && return
            _cleanup_done=true
            log "Stopping..."
            kill $SENDER_PID $EXPIRY_PID 2>/dev/null || true
            rm -f "$PID_FILE"
        }
        trap 'cleanup; exit 0' SIGTERM SIGINT
        trap 'cleanup' EXIT

        # Receive beacons (blocking — this is the main loop)
        # Retry if socat dies (e.g., interface goes down temporarily)
        RETRY_DELAY=5
        while true; do
            receive_beacons
            # If receive_beacons ran for >60s, it was working — reset backoff
            if [ -f "$PEER_FILE" ] && [ "$(wc -l < "$PEER_FILE" 2>/dev/null || echo 0)" -gt 0 ]; then
                RETRY_DELAY=5
            fi
            log "WARNING: socat exited — retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
            # Cap backoff at 30s
            RETRY_DELAY=$((RETRY_DELAY < 30 ? RETRY_DELAY * 2 : 30))
        done
        ;;

    stop)
        if [ -f "$PID_FILE" ]; then
            PID=$(cat "$PID_FILE")
            # Validate PID is numeric and belongs to a discovery process
            if [[ "$PID" =~ ^[0-9]+$ ]] && kill -0 "$PID" 2>/dev/null; then
                PROC_CMD=$(cat "/proc/$PID/cmdline" 2>/dev/null | tr '\0' ' ' || true)
                if echo "$PROC_CMD" | grep -q "node-discovery"; then
                    kill "$PID" 2>/dev/null || true
                    log "Stopped (PID $PID)"
                else
                    log "PID $PID is not a discovery process — removing stale PID file"
                fi
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
