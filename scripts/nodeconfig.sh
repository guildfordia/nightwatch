#!/bin/bash
# Nightwatch — Node auto-configuration from hostname
#
# Runs on every boot BEFORE the mesh service.
# Derives PI_NUMBER from hostname (e.g. "nightwatch-3" → PI_NUMBER=3)
# Generates .env and ngircd.conf if missing.
#
# Hostname convention: nightwatch-<N>  (e.g. nightwatch-1, nightwatch-2)
# Gateway convention:  nightwatch-gw   or pass NIGHTWATCH_GATEWAY=true
#
# This enables the "flash and forget" workflow:
#   Pi Imager → set hostname → boot → auto-join mesh

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

if [ ! -d "$NIGHTWATCH_DIR" ]; then
    log "Error: $NIGHTWATCH_DIR not found"
    exit 1
fi

if [ ! -f "$ENV_TEMPLATE" ]; then
    log "Error: $ENV_TEMPLATE not found"
    exit 1
fi

# ---- Derive node number from hostname ----

HOSTNAME=$(hostname)
log "Hostname: $HOSTNAME"

# Extract number from hostname patterns:
#   nightwatch-1, nightwatch-2, nw-3, nightwatch-gw, etc.
NODE_NUM=""
IS_GATEWAY=false

if [[ "$HOSTNAME" =~ -gw$ ]] || [[ "$HOSTNAME" =~ -gateway$ ]]; then
    IS_GATEWAY=true
    # Gateway: extract number if present (nightwatch-gw-1), otherwise default to 1
    NODE_NUM=$(echo "$HOSTNAME" | grep -oP '\d+' | tail -1)
    NODE_NUM="${NODE_NUM:-1}"
    log "Gateway mode detected"
elif [[ "$HOSTNAME" =~ ([0-9]+)$ ]]; then
    NODE_NUM="${BASH_REMATCH[1]}"
else
    log "Warning: cannot derive node number from hostname '$HOSTNAME'"
    log "Expected format: nightwatch-<N> (e.g. nightwatch-1)"
    log "Defaulting to node 1"
    NODE_NUM=1
fi

log "Node number: $NODE_NUM"

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
        tailscale up --auth-key="$TAILSCALE_AUTH_KEY" --accept-routes --hostname="$(hostname)" 2>/dev/null || true
        tailscale set --accept-dns=false 2>/dev/null || true
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
