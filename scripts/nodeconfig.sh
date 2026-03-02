#!/bin/bash
# Nightwatch — Node auto-configuration
#
# Runs on every boot BEFORE the mesh service.
# Determines this node's number by:
#   1. Scanning the mesh for existing nodes
#   2. If we have a saved number and it's not taken, keep it
#   3. Otherwise, pick the lowest available number
#
# This ensures no conflicts even when multiple clones boot from the
# same golden image. Each node always verifies its number is unique.
#
# Generates .env and ngircd.conf based on the node number.
#
# This enables the "flash and forget" workflow:
#   Flash golden image → boot → auto-picks unique node number → joins mesh

set -euo pipefail

LOG_TAG="nightwatch-nodeconfig"
log() { echo "[nodeconfig] $1"; logger -t "$LOG_TAG" "$1" 2>/dev/null || true; }

# Read project path from /etc/nightwatch.conf (written by setup-rpi.sh)
if [ -f /etc/nightwatch.conf ]; then
    # shellcheck source=/dev/null
    source /etc/nightwatch.conf
fi
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-/opt/nightwatch}"

# shellcheck source=common.sh
source "$NIGHTWATCH_DIR/scripts/common.sh"
ENV_FILE="$NIGHTWATCH_DIR/.env"
ENV_TEMPLATE="$NIGHTWATCH_DIR/.env.example"
NODE_NUM_FILE="$NIGHTWATCH_DIR/.node-number"

# Ensure SSH host keys exist (build-image.sh deletes them for cloning)
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    log "Regenerating SSH host keys..."
    ssh-keygen -A >/dev/null 2>&1 || true
    systemctl restart sshd 2>/dev/null || true
fi

if [ ! -d "$NIGHTWATCH_DIR" ]; then
    log "Error: $NIGHTWATCH_DIR not found"
    exit 1
fi

if [ ! -f "$ENV_TEMPLATE" ]; then
    log "Error: $ENV_TEMPLATE not found"
    exit 1
fi

# ---- Sync service files to systemd ----
# Ensures golden image clones and updates always have the latest service files
SERVICES_UPDATED=false
for svc in nightwatch-nodeconfig nightwatch-mesh nightwatch-discovery nightwatch-docker; do
    SRC="$NIGHTWATCH_DIR/scripts/${svc}.service"
    DST="/etc/systemd/system/${svc}.service"
    if [ -f "$SRC" ]; then
        # Render the service file (replace /opt/nightwatch with actual path)
        RENDERED=$(sed "s|/opt/nightwatch|$NIGHTWATCH_DIR|g" "$SRC")
        if [ ! -f "$DST" ] || [ "$RENDERED" != "$(cat "$DST")" ]; then
            echo "$RENDERED" > "$DST"
            SERVICES_UPDATED=true
            log "Updated ${svc}.service"
        fi
    fi
done
if [ "$SERVICES_UPDATED" = true ]; then
    systemctl daemon-reload
    log "systemd reloaded"
fi

# Ensure Docker DNS is configured
if [ ! -f /etc/docker/daemon.json ]; then
    mkdir -p /etc/docker
    echo '{"dns":["8.8.8.8","1.1.1.1"]}' > /etc/docker/daemon.json
    log "Docker DNS configured"
fi

# Load mesh config defaults from template
MESH_IFACE="wlan1"
MESH_ID="nightwatch"
FREQ="2412"
if [ -f "$ENV_TEMPLATE" ]; then
    MESH_IFACE=$(grep '^MESH_IFACE=' "$ENV_TEMPLATE" | cut -d= -f2 || echo "wlan1")
    MESH_ID=$(grep '^MESH_ID=' "$ENV_TEMPLATE" | cut -d= -f2 || echo "nightwatch")
    FREQ=$(grep '^FREQ=' "$ENV_TEMPLATE" | cut -d= -f2 || echo "2412")
fi

# ---- Mesh scan function ----

# Brings up a temporary mesh, scans for taken node numbers, tears it down.
# Sets TAKEN (space-separated list of taken numbers) and TEMP_MESH.
TAKEN=""
TEMP_MESH=false

scan_mesh() {
    log "Bringing up temporary mesh for network scan..."
    TEMP_MESH=false

    # Release interface from NetworkManager
    nmcli dev set "$MESH_IFACE" managed no 2>/dev/null || true
    pkill -f "wpa_supplicant.*$MESH_IFACE" 2>/dev/null || true
    sleep 1
    # Force-kill if SIGTERM was ignored
    if pgrep -f "wpa_supplicant.*$MESH_IFACE" >/dev/null 2>&1; then
        pkill -9 -f "wpa_supplicant.*$MESH_IFACE" 2>/dev/null || true
        sleep 1
    fi

    # Load batman-adv
    modprobe batman-adv 2>/dev/null || true

    # Set up mesh interface
    ip link set "$MESH_IFACE" down 2>/dev/null || true
    if iw dev "$MESH_IFACE" set type mesh 2>/dev/null; then
        ip link set "$MESH_IFACE" up
        sleep 1
        iw dev "$MESH_IFACE" mesh join "$MESH_ID" freq "$FREQ" 2>/dev/null || true
        sleep 1

        # Add to batman-adv
        batctl meshif bat0 if add "$MESH_IFACE" 2>/dev/null || true
        ip link set bat0 up 2>/dev/null || true

        # Assign a temporary scan IP (.250) to check which nodes exist
        ip addr add 192.168.199.250/24 dev bat0 2>/dev/null || true
        sleep 2

        TEMP_MESH=true
        log "Temporary mesh is up, scanning..."
    else
        log "Warning: could not set $MESH_IFACE to mesh mode"
    fi

    # Scan for taken node numbers
    TAKEN=""
    if [ "$TEMP_MESH" = true ]; then
        if command -v fping >/dev/null 2>&1; then
            # fping pings all 20 IPs in parallel — much faster than sequential ping
            IPS=$(for i in $(seq 1 "$MAX_NODES"); do mesh_ip_for_node "$i"; done)
            ALIVE=$(echo "$IPS" | fping -a -q -r 1 -t 500 2>/dev/null || true)
            for ip in $ALIVE; do
                i=$((${ip##*.} - 100))
                TAKEN="$TAKEN $i"
                log "  Node $i is taken ($ip responds)"
            done
        else
            # Fallback: parallel ping via background jobs (fping not yet installed)
            PING_DIR=$(mktemp -d /tmp/nightwatch-ping.XXXXXX)
            for i in $(seq 1 "$MAX_NODES"); do
                ip="$(mesh_ip_for_node "$i")"
                ( ping -c 1 -W 1 "$ip" >/dev/null 2>&1 && echo "$i" > "$PING_DIR/$i" ) &
            done
            wait
            for f in "$PING_DIR"/*; do
                [ -f "$f" ] || continue
                i=$(cat "$f")
                TAKEN="$TAKEN $i"
                log "  Node $i is taken ($(mesh_ip_for_node "$i") responds)"
            done
            rm -rf "$PING_DIR"
        fi
    fi
}

teardown_mesh() {
    if [ "$TEMP_MESH" = true ]; then
        ip addr del 192.168.199.250/24 dev bat0 2>/dev/null || true
        batctl meshif bat0 if del "$MESH_IFACE" 2>/dev/null || true
        ip link set bat0 down 2>/dev/null || true
        iw dev "$MESH_IFACE" mesh leave 2>/dev/null || true
        ip link set "$MESH_IFACE" down 2>/dev/null || true
        TEMP_MESH=false
        log "Temporary mesh torn down"
    fi
}

# ---- Determine node number ----

CURRENT_HOSTNAME=$(hostname)
log "Hostname: $CURRENT_HOSTNAME"

IS_GATEWAY=false

# Check for gateway hostname (matches nightwatch-gw-3, nightwatch-gw, nightwatch-gateway)
if [[ "$CURRENT_HOSTNAME" =~ -gw(-|$) ]] || [[ "$CURRENT_HOSTNAME" =~ -gateway(-|$) ]]; then
    IS_GATEWAY=true
    log "Gateway mode detected"
fi

# Check gateway flag in .secrets
SECRETS_FILE="$NIGHTWATCH_DIR/.secrets"
if [ -f "$SECRETS_FILE" ] && grep -q '^MESH_GATEWAY=true' "$SECRETS_FILE" 2>/dev/null; then
    IS_GATEWAY=true
    log "Gateway mode from .secrets"
fi

# Ensure temporary mesh is torn down on exit (e.g., if script crashes mid-scan)
trap 'teardown_mesh' EXIT

# Random delay (1-8s) to reduce collision when multiple Pis boot together
DELAY=$((RANDOM % 8 + 1))
log "Waiting ${DELAY}s before scanning (collision avoidance)..."
sleep "$DELAY"

# Always scan the mesh to check for conflicts
scan_mesh

# Try to use saved node number first (if not taken)
NODE_NUM=""
if [ -f "$NODE_NUM_FILE" ]; then
    SAVED_NUM=$(cat "$NODE_NUM_FILE")
    if [[ "$SAVED_NUM" =~ ^[0-9]+$ ]] && [ "$SAVED_NUM" -ge 1 ] && [ "$SAVED_NUM" -le "$MAX_NODES" ]; then
        if [ -z "$TAKEN" ] || ! echo "$TAKEN" | grep -qw "$SAVED_NUM"; then
            NODE_NUM="$SAVED_NUM"
            log "Using saved node number: $NODE_NUM (verified available)"
        else
            log "Saved node number $SAVED_NUM is taken — reassigning"
        fi
    fi
fi

# If no valid saved number, pick the lowest available
if [ -z "$NODE_NUM" ]; then
    for i in $(seq 1 "$MAX_NODES"); do
        if [ -z "$TAKEN" ] || ! echo "$TAKEN" | grep -qw "$i"; then
            NODE_NUM="$i"
            break
        fi
    done
    NODE_NUM="${NODE_NUM:-1}"
    log "Assigned node number: $NODE_NUM (taken=[${TAKEN# }])"
fi

# Tear down temporary mesh (the mesh service will do the real setup)
teardown_mesh

# Save node number for next boot
echo "$NODE_NUM" > "$NODE_NUM_FILE"
log "Node number: $NODE_NUM (saved to $NODE_NUM_FILE)"

# Set hostname to match the assigned number
if [ "$IS_GATEWAY" = true ]; then
    NEW_HOSTNAME="nightwatch-gw-${NODE_NUM}"
else
    NEW_HOSTNAME="nightwatch-${NODE_NUM}"
fi
if [ "$CURRENT_HOSTNAME" != "$NEW_HOSTNAME" ]; then
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || echo "$NEW_HOSTNAME" > /etc/hostname
    sed -i "s/^127\.0\.1\.1[[:space:]]\+[^#]*/127.0.1.1\t$NEW_HOSTNAME /" /etc/hosts 2>/dev/null || true
    if ! grep -q "$NEW_HOSTNAME" /etc/hosts 2>/dev/null; then
        echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
    fi
    ACTUAL_HOSTNAME=$(hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "")
    if [ "$ACTUAL_HOSTNAME" = "$NEW_HOSTNAME" ]; then
        log "Hostname set to $NEW_HOSTNAME"
    else
        log "Warning: hostname change to $NEW_HOSTNAME may not have taken effect (got: $ACTUAL_HOSTNAME)"
    fi
fi

# ---- Check if .env already exists and is valid ----

if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    EXISTING_NUM="${PI_NUMBER:-}"
    if [ "$EXISTING_NUM" = "$NODE_NUM" ]; then
        log ".env already configured for node $NODE_NUM — skipping generation"
        # Generate ngircd.conf if missing (discovery daemon will update peers later)
        if [ ! -f "$NIGHTWATCH_DIR/ngircd/ngircd.conf" ]; then
            if [ -x "$NIGHTWATCH_DIR/scripts/setup-distributed-irc.sh" ]; then
                cd "$NIGHTWATCH_DIR"
                log "Generating initial ngircd.conf..."
                "$NIGHTWATCH_DIR/scripts/setup-distributed-irc.sh"
            fi
        fi
        exit 0
    fi
    log "Node number changed ($EXISTING_NUM → $NODE_NUM) — regenerating config"
fi

# ---- Generate .env from template ----

log "Generating .env for node $NODE_NUM..."

cp "$ENV_TEMPLATE" "$ENV_FILE"

# Calculate mesh IP: 192.168.199.(100 + node_number)
if ! MESH_IP="$(mesh_ip_for_node "$NODE_NUM")"; then
    log "Error: invalid node number $NODE_NUM"
    exit 1
fi

# Set node-specific values
set_env_value "$ENV_FILE" "PI_NUMBER" "$NODE_NUM"
set_env_value "$ENV_FILE" "MESH_IP" "$MESH_IP"

# Gateway config
if [ "$IS_GATEWAY" = true ]; then
    set_env_value "$ENV_FILE" "MESH_GATEWAY" "true"
    set_env_value "$ENV_FILE" "INET_IFACE" "eth0"
    log "Gateway mode enabled"
fi

# Inject secrets from .secrets file (preserved by build-image.sh)
if [ -f "$SECRETS_FILE" ]; then
    log "Injecting secrets from .secrets..."
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        # Skip malformed lines (must contain =)
        [[ "$line" != *=* ]] && continue
        # Split on first = only (preserves = in values like base64 tokens)
        key="${line%%=*}"
        value="${line#*=}"
        [[ -z "$key" ]] && continue
        [[ "$key" = "MESH_GATEWAY" ]] && continue
        # Use set_env_value — no escaping needed
        set_env_value "$ENV_FILE" "$key" "$value"
    done < "$SECRETS_FILE"
    log "Secrets injected"
fi

log "Config: PI_NUMBER=$NODE_NUM MESH_IP=$MESH_IP GATEWAY=$IS_GATEWAY"

# ---- Tailscale setup (if auth key present and not yet connected) ----

# shellcheck source=/dev/null
source "$ENV_FILE"
if [ -n "${TAILSCALE_AUTH_KEY:-}" ] && command -v tailscale >/dev/null 2>&1; then
    if [[ ! "$TAILSCALE_AUTH_KEY" =~ ^tskey- ]]; then
        log "Warning: TAILSCALE_AUTH_KEY doesn't start with 'tskey-' — skipping Tailscale setup"
    else
        TS_STATUS=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4 || echo "")
        if [ "$TS_STATUS" != "Running" ]; then
            log "Connecting to Tailscale..."
            systemctl start tailscaled 2>/dev/null || true
            # Write auth key to temp file to avoid exposing it in ps output
            TS_KEY_FILE=$(mktemp /tmp/nightwatch-ts-key.XXXXXX)
            # Ensure key file is always cleaned up, even on interrupt
            trap 'rm -f "$TS_KEY_FILE" 2>/dev/null; teardown_mesh' EXIT
            chmod 600 "$TS_KEY_FILE"
            printf '%s' "$TAILSCALE_AUTH_KEY" > "$TS_KEY_FILE"
            tailscale up --auth-key="file:$TS_KEY_FILE" --accept-routes --accept-dns=false --hostname="$(hostname)" --reset 2>/dev/null || true
            rm -f "$TS_KEY_FILE"
            # Restore original trap
            trap 'teardown_mesh' EXIT
            log "Tailscale connected: $(tailscale ip --4 2>/dev/null || echo 'pending')"
        else
            log "Tailscale already running"
        fi
    fi
fi

# ---- Generate ngircd config ----

if [ -x "$NIGHTWATCH_DIR/scripts/setup-distributed-irc.sh" ]; then
    log "Generating ngircd.conf..."
    cd "$NIGHTWATCH_DIR"
    "$NIGHTWATCH_DIR/scripts/setup-distributed-irc.sh"
    log "ngircd.conf generated"
else
    log "Warning: setup-distributed-irc.sh not found"
fi

log "Node configuration complete"
