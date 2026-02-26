#!/bin/bash
# Nightwatch — Node auto-configuration
#
# Runs on every boot BEFORE the mesh service.
# Determines this node's number via (in order of priority):
#   1. Saved number from previous boot (.node-number file)
#   2. Number in hostname (e.g. nightwatch-3 → node 3)
#   3. Dynamic assignment: scan the mesh for existing nodes, pick lowest available
#
# Generates .env and ngircd.conf based on the node number.
#
# This enables the "flash and forget" workflow:
#   Flash golden image → boot → auto-picks node number → joins mesh

set -euo pipefail

LOG_TAG="nightwatch-nodeconfig"
log() { echo "[nodeconfig] $1"; logger -t "$LOG_TAG" "$1" 2>/dev/null || true; }

# Read project path from /etc/nightwatch.conf (written by setup-rpi.sh)
if [ -f /etc/nightwatch.conf ]; then
    # shellcheck source=/dev/null
    source /etc/nightwatch.conf
fi
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-/opt/nightwatch}"
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

# Load mesh config defaults from template
MESH_IFACE="wlan1"
MESH_ID="nightwatch"
FREQ="2412"
if [ -f "$ENV_TEMPLATE" ]; then
    MESH_IFACE=$(grep '^MESH_IFACE=' "$ENV_TEMPLATE" | cut -d= -f2 || echo "wlan1")
    MESH_ID=$(grep '^MESH_ID=' "$ENV_TEMPLATE" | cut -d= -f2 || echo "nightwatch")
    FREQ=$(grep '^FREQ=' "$ENV_TEMPLATE" | cut -d= -f2 || echo "2412")
fi

# ---- Determine node number ----

CURRENT_HOSTNAME=$(hostname)
log "Hostname: $CURRENT_HOSTNAME"

NODE_NUM=""
IS_GATEWAY=false

# Check for gateway hostname
if [[ "$CURRENT_HOSTNAME" =~ -gw$ ]] || [[ "$CURRENT_HOSTNAME" =~ -gateway$ ]]; then
    IS_GATEWAY=true
    log "Gateway mode detected"
fi

# Priority 1: Saved node number from previous boot
if [ -f "$NODE_NUM_FILE" ]; then
    SAVED_NUM=$(cat "$NODE_NUM_FILE")
    if [[ "$SAVED_NUM" =~ ^[0-9]+$ ]] && [ "$SAVED_NUM" -ge 1 ] && [ "$SAVED_NUM" -le 20 ]; then
        NODE_NUM="$SAVED_NUM"
        log "Using saved node number: $NODE_NUM"
    fi
fi

# Priority 2: Number in hostname (e.g. nightwatch-3)
if [ -z "$NODE_NUM" ] && [[ "$CURRENT_HOSTNAME" =~ ([0-9]+) ]]; then
    NODE_NUM="${BASH_REMATCH[1]}"
    log "Node number from hostname: $NODE_NUM"
fi

# Priority 3: Dynamic assignment — scan mesh for existing nodes
if [ -z "$NODE_NUM" ]; then
    log "No node number found — starting dynamic assignment..."

    # Random delay (1-5s) to reduce collision when multiple Pis boot together
    DELAY=$((RANDOM % 5 + 1))
    log "Waiting ${DELAY}s before scanning (collision avoidance)..."
    sleep "$DELAY"

    # Temporarily bring up mesh interface to scan for existing nodes
    log "Bringing up temporary mesh for network scan..."
    TEMP_MESH=false

    # Release interface from NetworkManager
    nmcli dev set "$MESH_IFACE" managed no 2>/dev/null || true
    pkill -f "wpa_supplicant.*$MESH_IFACE" 2>/dev/null || true
    sleep 1

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
        log "Warning: could not set $MESH_IFACE to mesh mode — assigning node 1"
    fi

    # Scan for taken node numbers
    TAKEN=""
    if [ "$TEMP_MESH" = true ]; then
        for i in $(seq 1 20); do
            ip="192.168.199.$((100 + i))"
            if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
                TAKEN="$TAKEN $i"
                log "  Node $i is taken ($ip responds)"
            fi
        done
    fi

    # Pick lowest available number
    for i in $(seq 1 20); do
        if ! echo "$TAKEN" | grep -qw "$i"; then
            NODE_NUM="$i"
            break
        fi
    done
    NODE_NUM="${NODE_NUM:-1}"
    log "Assigned node number: $NODE_NUM (scanned: taken=[${TAKEN# }])"

    # Tear down temporary mesh (the mesh service will do the real setup)
    if [ "$TEMP_MESH" = true ]; then
        ip addr del 192.168.199.250/24 dev bat0 2>/dev/null || true
        batctl meshif bat0 if del "$MESH_IFACE" 2>/dev/null || true
        ip link set bat0 down 2>/dev/null || true
        iw dev "$MESH_IFACE" mesh leave 2>/dev/null || true
        ip link set "$MESH_IFACE" down 2>/dev/null || true
        log "Temporary mesh torn down"
    fi

    # Set hostname to match the assigned number
    if [ "$IS_GATEWAY" = true ]; then
        NEW_HOSTNAME="nightwatch-gw-${NODE_NUM}"
    else
        NEW_HOSTNAME="nightwatch-${NODE_NUM}"
    fi
    hostnamectl set-hostname "$NEW_HOSTNAME" 2>/dev/null || echo "$NEW_HOSTNAME" > /etc/hostname
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts 2>/dev/null || true
    if ! grep -q "$NEW_HOSTNAME" /etc/hosts 2>/dev/null; then
        echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
    fi
    log "Hostname set to $NEW_HOSTNAME"
fi

# Save node number for next boot
echo "$NODE_NUM" > "$NODE_NUM_FILE"
log "Node number: $NODE_NUM (saved to $NODE_NUM_FILE)"

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
MESH_IP="192.168.199.$((100 + NODE_NUM))"

# Set node-specific values
sed -i "s/^PI_NUMBER=.*/PI_NUMBER=$NODE_NUM/" "$ENV_FILE"
sed -i "s/^MESH_IP=.*/MESH_IP=$MESH_IP/" "$ENV_FILE"

# Gateway config
if [ "$IS_GATEWAY" = true ]; then
    sed -i "s/^MESH_GATEWAY=.*/MESH_GATEWAY=true/" "$ENV_FILE"
    sed -i "s/^# INET_IFACE=eth0/INET_IFACE=eth0/" "$ENV_FILE"
    log "Gateway mode enabled"
fi

# Inject secrets from .secrets file (preserved by build-image.sh)
SECRETS_FILE="$NIGHTWATCH_DIR/.secrets"
if [ -f "$SECRETS_FILE" ]; then
    log "Injecting secrets from .secrets..."
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        # Replace the value in .env
        sed -i "s/^${key}=.*/${key}=${value}/" "$ENV_FILE"
    done < "$SECRETS_FILE"
    log "Secrets injected"
fi

log "Config: PI_NUMBER=$NODE_NUM MESH_IP=$MESH_IP GATEWAY=$IS_GATEWAY"

# ---- Tailscale setup (if auth key present and not yet connected) ----

# shellcheck source=/dev/null
source "$ENV_FILE"
if [ -n "${TAILSCALE_AUTH_KEY:-}" ] && command -v tailscale >/dev/null 2>&1; then
    TS_STATUS=$(tailscale status --json 2>/dev/null | grep -o '"BackendState":"[^"]*"' | cut -d'"' -f4 || echo "")
    if [ "$TS_STATUS" != "Running" ]; then
        log "Connecting to Tailscale..."
        systemctl start tailscaled 2>/dev/null || true
        tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --accept-routes --accept-dns=false --hostname="$(hostname)" --reset 2>/dev/null || true
        log "Tailscale connected: $(tailscale ip --4 2>/dev/null || echo 'pending')"
    else
        log "Tailscale already running"
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
