#!/bin/bash
# Nightwatch — Node auto-configuration
#
# Runs on every boot BEFORE the mesh service.
# Determines this node's number by:
#   1. If .node-number has FIXED marker (set at SD card prep), use it as-is
#   2. Otherwise, scan the mesh for existing nodes
#   3. If we have a saved number and it's not taken, keep it
#   4. Otherwise, pick the lowest available number
#
# Fixed IDs (from prepare-sdcard.sh --node N) are never reassigned.
# Generates .env and ngircd.conf based on the node number.

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
RESTART_SERVICES=false

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
for svc in nightwatch-nodeconfig nightwatch-mesh nightwatch-discovery nightwatch-app nightwatch-bridge nightwatch-led nightwatch-debug; do
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
# Migrate legacy nightwatch-docker.service → nightwatch-app.service
if [ -f /etc/systemd/system/nightwatch-docker.service ]; then
    systemctl stop nightwatch-docker.service 2>/dev/null || true
    systemctl disable nightwatch-docker.service 2>/dev/null || true
    rm -f /etc/systemd/system/nightwatch-docker.service
    SERVICES_UPDATED=true
    log "Migrated nightwatch-docker → nightwatch-app"
fi

if [ "$SERVICES_UPDATED" = true ]; then
    systemctl daemon-reload
    log "systemd reloaded"
fi

# Ensure irc-bridge data directory exists
mkdir -p "$NIGHTWATCH_DIR/irc-bridge-go/data" 2>/dev/null || true

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

    # Permanently tell NetworkManager to never manage the mesh interface.
    # Without this, NM reclaims wlan1 after teardown and the repeated
    # firmware load/unload cycles crash the ath9k_htc dongle.
    NM_UNMANAGED_CONF="/etc/NetworkManager/conf.d/nightwatch-mesh-unmanaged.conf"
    if [ ! -f "$NM_UNMANAGED_CONF" ] && [ -d /etc/NetworkManager ]; then
        mkdir -p /etc/NetworkManager/conf.d
        cat > "$NM_UNMANAGED_CONF" << NMEOF
[keyfile]
unmanaged-devices=interface-name:${MESH_IFACE};interface-name:wlan2
NMEOF
        nmcli general reload 2>/dev/null || true
        log "NetworkManager: $MESH_IFACE and wlan2 permanently set to unmanaged"
    fi

    # Release interface from NetworkManager (immediate effect)
    nmcli dev set "$MESH_IFACE" managed no 2>/dev/null || true
    pkill -f "wpa_supplicant.*$MESH_IFACE" 2>/dev/null || true
    sleep 1
    # Force-kill if SIGTERM was ignored
    if pgrep -f "wpa_supplicant.*$MESH_IFACE" >/dev/null 2>&1; then
        pkill -9 -f "wpa_supplicant.*$MESH_IFACE" 2>/dev/null || true
        sleep 1
    fi

    # Wait for the dongle to appear (it may not be ready immediately after boot).
    # Give it up to 30s — if still missing, abort the scan rather than hanging.
    DONGLE_TIMEOUT=30
    DONGLE_WAIT=0
    while [ ! -d "/sys/class/net/$MESH_IFACE" ] && [ "$DONGLE_WAIT" -lt "$DONGLE_TIMEOUT" ]; do
        if [ "$DONGLE_WAIT" -eq 0 ]; then
            log "Waiting for $MESH_IFACE to appear (up to ${DONGLE_TIMEOUT}s)..."
        fi
        sleep 2
        DONGLE_WAIT=$((DONGLE_WAIT + 2))
    done
    if [ ! -d "/sys/class/net/$MESH_IFACE" ]; then
        log "Error: $MESH_IFACE not found after ${DONGLE_TIMEOUT}s — skipping mesh scan"
        return
    fi

    # Check if the dongle is responsive; if not, try a USB reset
    if ! iw dev "$MESH_IFACE" info >/dev/null 2>&1; then
        log "Warning: $MESH_IFACE not responding — attempting USB reset..."
        USB_PATH=$(readlink -f "/sys/class/net/$MESH_IFACE/device/.." 2>/dev/null || true)
        if [ -n "$USB_PATH" ] && [ -f "$USB_PATH/authorized" ]; then
            echo 0 > "$USB_PATH/authorized"
            sleep 2
            echo 1 > "$USB_PATH/authorized"
            sleep 5
            log "USB reset done, waiting for $MESH_IFACE..."
        else
            # Fallback: unbind/rebind the USB device
            USB_DEV=$(basename "$(readlink -f /sys/class/net/$MESH_IFACE/device 2>/dev/null)" 2>/dev/null || true)
            USB_DRIVER=$(readlink -f "/sys/class/net/$MESH_IFACE/device/driver" 2>/dev/null || true)
            if [ -n "$USB_DEV" ] && [ -n "$USB_DRIVER" ]; then
                echo "$USB_DEV" > "$USB_DRIVER/unbind" 2>/dev/null || true
                sleep 2
                echo "$USB_DEV" > "$USB_DRIVER/bind" 2>/dev/null || true
                sleep 5
                log "USB unbind/rebind done"
            else
                log "Warning: could not reset USB device for $MESH_IFACE"
            fi
        fi
        # Final check after reset — abort if still not working
        if ! iw dev "$MESH_IFACE" info >/dev/null 2>&1; then
            log "Error: $MESH_IFACE still not responding after USB reset — skipping mesh scan"
            return
        fi
    fi

    # Load batman-adv
    modprobe batman-adv 2>/dev/null || true

    # Set up mesh interface (timeout protects against driver hangs)
    ip link set "$MESH_IFACE" down 2>/dev/null || true
    if timeout 10 iw dev "$MESH_IFACE" set type mesh 2>/dev/null; then
        ip link set "$MESH_IFACE" up
        sleep 1
        iw dev "$MESH_IFACE" mesh join "$MESH_ID" freq "$FREQ" 2>/dev/null || true
        sleep 1

        # Add to batman-adv
        batctl meshif bat0 if add "$MESH_IFACE" 2>/dev/null || true
        ip link set bat0 up 2>/dev/null || true

        TEMP_MESH=true

        # Wait for batman-adv to converge and neighbor count to stabilize.
        # All nodes must see the same set of neighbors for MAC-based assignment
        # to be consistent. Uses adaptive detection: check every 5s, consider
        # converged after 3 consecutive stable checks (15s of stability).
        # Initial 15s grace period lets other nodes boot. Max 90s timeout.
        # This only runs on first boot (no .node-number file) — subsequent
        # boots use the saved number and skip the scan.
        CONVERGE_INTERVAL=5
        CONVERGE_STABLE_NEEDED=3
        CONVERGE_MAX=90
        CONVERGE_GRACE=15

        log "Temporary mesh is up, waiting ${CONVERGE_GRACE}s grace period..."
        sleep "$CONVERGE_GRACE"

        log "Checking neighbor convergence (every ${CONVERGE_INTERVAL}s, need ${CONVERGE_STABLE_NEEDED} stable, max ${CONVERGE_MAX}s)..."
        PREV_COUNT=-1
        STABLE_FOR=0
        ELAPSED=$CONVERGE_GRACE
        while [ "$ELAPSED" -lt "$CONVERGE_MAX" ]; do
            # Count neighbors — skip header lines (first 2 lines of batctl output)
            CUR_COUNT=$(batctl meshif bat0 n 2>/dev/null | tail -n +3 | grep -c "$MESH_IFACE" || true)
            CUR_COUNT=${CUR_COUNT:-0}
            if [ "$CUR_COUNT" -eq "$PREV_COUNT" ]; then
                STABLE_FOR=$((STABLE_FOR + 1))
            else
                STABLE_FOR=0
                PREV_COUNT=$CUR_COUNT
            fi
            log "  convergence ${ELAPSED}s/${CONVERGE_MAX}s: $CUR_COUNT neighbor(s) (stable for ${STABLE_FOR}/${CONVERGE_STABLE_NEEDED})"
            if [ "$STABLE_FOR" -ge "$CONVERGE_STABLE_NEEDED" ]; then
                log "Mesh converged after ${ELAPSED}s"
                break
            fi
            sleep "$CONVERGE_INTERVAL"
            ELAPSED=$((ELAPSED + CONVERGE_INTERVAL))
        done
        if [ "$ELAPSED" -ge "$CONVERGE_MAX" ]; then
            log "Warning: convergence timeout after ${CONVERGE_MAX}s — proceeding with $CUR_COUNT neighbor(s)"
        fi
        log "Scanning with $CUR_COUNT neighbor(s)..."
    else
        log "Warning: could not set $MESH_IFACE to mesh mode"
    fi

    # Determine how many nodes are on the mesh using batman-adv neighbors.
    # IP-based scanning doesn't work reliably because ARP can't resolve across
    # batman-adv when the remote IP is on a bridge (br0) and we're not bridged.
    # Instead, count batman-adv neighbors (L2) — this is always reliable.
    MESH_PEER_COUNT=0
    TAKEN=""
    if [ "$TEMP_MESH" = true ]; then
        # Get our wlan1 MAC and all neighbor MACs, sort them to assign
        # deterministic node numbers. Each node's position in the sorted
        # MAC list determines its node number.
        OUR_MAC=$(cat "/sys/class/net/$MESH_IFACE/address" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
        # Collect neighbor MACs from batman-adv (skip 2 header lines to avoid
        # parsing "adv" from "[B.A.T.M.A.N. adv ...]" as a MAC address)
        # Note: batctl exits non-zero when there are no neighbors, so || true
        # is required to prevent pipefail + set -e from killing the script.
        NEIGHBOR_MACS=$(batctl meshif bat0 n 2>/dev/null | tail -n +3 | awk '{print $2}' | tr '[:upper:]' '[:lower:]' | sort || true)
        MESH_PEER_COUNT=$(echo "$NEIGHBOR_MACS" | grep -c . || true)
        MESH_PEER_COUNT=${MESH_PEER_COUNT:-0}
        log "batman-adv sees $MESH_PEER_COUNT neighbor(s) on mesh"

        if [ -n "$NEIGHBOR_MACS" ] && [ "$MESH_PEER_COUNT" -gt 0 ]; then
            # Build sorted list of all MACs (ours + neighbors)
            ALL_MACS=$(printf '%s\n%s\n' "$OUR_MAC" "$NEIGHBOR_MACS" | sort -u)
            # Our position in the sorted list is our node number
            OUR_POSITION=1
            while IFS= read -r mac; do
                if [ "$mac" = "$OUR_MAC" ]; then
                    break
                fi
                OUR_POSITION=$((OUR_POSITION + 1))
            done <<< "$ALL_MACS"
            # Mark all positions except ours as taken
            TOTAL=$(echo "$ALL_MACS" | wc -l | tr -d ' ')
            for i in $(seq 1 "$TOTAL"); do
                if [ "$i" -ne "$OUR_POSITION" ]; then
                    TAKEN="$TAKEN $i"
                fi
            done
            log "MAC-based assignment: $TOTAL nodes on mesh, we are position $OUR_POSITION"
            log "  Our MAC: $OUR_MAC"
            log "  All MACs (sorted): $(echo "$ALL_MACS" | tr '\n' ' ')"
        else
            log "No neighbors found — we are the first node"
        fi
    fi
}

teardown_mesh() {
    if [ "$TEMP_MESH" = true ]; then
        batctl meshif bat0 if del "$MESH_IFACE" 2>/dev/null || true
        ip link set bat0 down 2>/dev/null || true
        # Do NOT bring wlan1 down or leave mesh mode here.
        # The ath9k_htc firmware crashes when wlan1 is cycled down/up,
        # leaving it missing when the mesh service starts.
        # mesh-fix.sh handles wlan1 setup from any state.
        TEMP_MESH=false
        log "Temporary scan done (bat0 cleaned, $MESH_IFACE left up for mesh service)"
    fi
}

# ---- Determine node number ----

CURRENT_HOSTNAME=$(hostname)
log "Hostname: $CURRENT_HOSTNAME"

# CdC §3.4 #10 — uniform node role. NODE_MODE was dropped; every node
# runs mesh + AP + eth0 sound-bridge subnet. The .secrets file may
# carry legacy NODE_MODE/MESH_GATEWAY entries from older SD prep
# runs — they are now ignored.
SECRETS_FILE="$NIGHTWATCH_DIR/.secrets"

# Ensure temporary mesh is torn down on exit (e.g., if script crashes mid-scan)
trap 'teardown_mesh' EXIT

# Try to use saved node number first (skip mesh scan on subsequent boots)
# The mesh scan stresses the ath9k_htc firmware (setup/teardown cycle) and
# can crash the dongle, leaving wlan1 missing when the mesh service starts.
# Only scan on first boot (no saved number) to avoid this.
NODE_NUM=""
IS_FIXED=false
if [ -f "$NODE_NUM_FILE" ]; then
    SAVED_NUM=$(head -1 "$NODE_NUM_FILE")
    # Check for FIXED marker (second line) — set at SD card prep time
    if sed -n '2p' "$NODE_NUM_FILE" 2>/dev/null | grep -q '^FIXED$'; then
        IS_FIXED=true
    fi
    if [[ "$SAVED_NUM" =~ ^[0-9]+$ ]] && [ "$SAVED_NUM" -ge 1 ] && [ "$SAVED_NUM" -le "$MAX_NODES" ]; then
        NODE_NUM="$SAVED_NUM"
        if [ "$IS_FIXED" = true ]; then
            log "Using FIXED node number: $NODE_NUM (assigned at SD card prep)"
        else
            log "Using saved node number: $NODE_NUM (from $NODE_NUM_FILE)"
        fi

        # Lightweight conflict check: if bat0 is already up (mesh service running),
        # verify our saved number matches our MAC position. This catches the case
        # where firstboot assigned #1 while solo, but now other nodes are on the mesh.
        # Skip this check for FIXED nodes — their number was assigned at SD card
        # prep time and tracked in the registry, so conflicts shouldn't happen.
        if [ "$IS_FIXED" = false ] && [ -d /sys/class/net/bat0 ]; then
            OUR_MAC=$(cat "/sys/class/net/$MESH_IFACE/address" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
            NEIGHBOR_MACS=$(batctl meshif bat0 n 2>/dev/null | tail -n +3 | awk '{print $2}' | tr '[:upper:]' '[:lower:]' | sort || true)
            if [ -n "$OUR_MAC" ] && [ -n "$NEIGHBOR_MACS" ]; then
                ALL_MACS=$(printf '%s\n%s\n' "$OUR_MAC" "$NEIGHBOR_MACS" | sort -u)
                CORRECT_POS=1
                while IFS= read -r mac; do
                    [ "$mac" = "$OUR_MAC" ] && break
                    CORRECT_POS=$((CORRECT_POS + 1))
                done <<< "$ALL_MACS"
                if [ "$CORRECT_POS" != "$NODE_NUM" ]; then
                    log "Conflict: saved #$NODE_NUM but MAC sort says #$CORRECT_POS — reassigning"
                    NODE_NUM="$CORRECT_POS"
                fi
            fi
        fi
    fi
fi

# Only scan the mesh if we don't have a saved node number (first boot)
if [ -z "$NODE_NUM" ]; then
    # Random delay (1-5s) to stagger mesh interface setup and avoid RF collisions
    DELAY=$((RANDOM % 5 + 1))
    log "Waiting ${DELAY}s before scanning (collision avoidance)..."
    sleep "$DELAY"

    scan_mesh

    # Pick the lowest available number
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
sync
log "Node number: $NODE_NUM (saved to $NODE_NUM_FILE)"

# Uniform hostname (CdC §3.4 #10) — no -gw-/-sb- suffix.
NEW_HOSTNAME="nightwatch-${NODE_NUM}"

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

# ---- Configure avahi (hostname + interface scoping) ----
# Always apply, even when hostname is unchanged, so code updates to the
# interface-scoping policy land on existing nodes without needing a
# hostname change to trigger the update.
#
# Interface scoping prevents mDNS collisions that suppress A records:
# each Pi has 4+ interfaces (wlan0 home LAN, wlan1 mesh, wlan2 AP, eth0,
# bat0, br0) and avahi's default (publish on all) means one Pi announces
# nightwatch-N from multiple MACs. Combined with batman-adv's L2 mDNS
# reflection across the mesh, avahi's collision detector trips and
# suppresses the A record — symptom: `_workstation._tcp` advertisement
# still visible but `nightwatch-N.local` fails to resolve.
#
# Policy: publish only on client-facing LAN interfaces. Mesh-facing
# interfaces (wlan1, bat0) and the bridge that carries mesh traffic (br0)
# are excluded. AP clients use IP/fixed config, not mDNS, so they don't
# need .local resolution.
AVAHI_CONF=/etc/avahi/avahi-daemon.conf
AVAHI_ALLOW_IFACES="wlan0,eth0"
AVAHI_CHANGED=false
if [ -f "$AVAHI_CONF" ]; then
    # host-name
    if grep -q '^host-name=' "$AVAHI_CONF" 2>/dev/null; then
        if ! grep -qx "host-name=$NEW_HOSTNAME" "$AVAHI_CONF"; then
            sed -i "s/^host-name=.*/host-name=$NEW_HOSTNAME/" "$AVAHI_CONF"
            AVAHI_CHANGED=true
        fi
    elif grep -q '^#host-name=' "$AVAHI_CONF" 2>/dev/null; then
        sed -i "s/^#host-name=.*/host-name=$NEW_HOSTNAME/" "$AVAHI_CONF"
        AVAHI_CHANGED=true
    else
        sed -i "/^\[server\]/a host-name=$NEW_HOSTNAME" "$AVAHI_CONF"
        AVAHI_CHANGED=true
    fi
    # allow-interfaces
    if grep -q '^allow-interfaces=' "$AVAHI_CONF" 2>/dev/null; then
        if ! grep -qx "allow-interfaces=$AVAHI_ALLOW_IFACES" "$AVAHI_CONF"; then
            sed -i "s/^allow-interfaces=.*/allow-interfaces=$AVAHI_ALLOW_IFACES/" "$AVAHI_CONF"
            AVAHI_CHANGED=true
        fi
    elif grep -q '^#allow-interfaces=' "$AVAHI_CONF" 2>/dev/null; then
        sed -i "s|^#allow-interfaces=.*|allow-interfaces=$AVAHI_ALLOW_IFACES|" "$AVAHI_CONF"
        AVAHI_CHANGED=true
    else
        sed -i "/^\[server\]/a allow-interfaces=$AVAHI_ALLOW_IFACES" "$AVAHI_CONF"
        AVAHI_CHANGED=true
    fi
fi

if [ "$AVAHI_CHANGED" = true ] && systemctl is-active --quiet avahi-daemon 2>/dev/null; then
    systemctl stop avahi-daemon 2>/dev/null || true
    systemctl start avahi-daemon
    log "Restarted avahi-daemon ($NEW_HOSTNAME.local on: $AVAHI_ALLOW_IFACES)"
fi

# ---- Ensure eth0 doesn't steal the default route from wlan0 ----
# wlan2 is the hostapd WiFi AP interface. eth0 is unused in mesh mode.
# sets a default route, it shadows wlan0 (which has actual internet) and breaks
# package installs during firstboot. Fix this early, before anything needs internet.
AP_IFACE="${AP_IFACE:-eth0}"
if ip route show default dev "$AP_IFACE" 2>/dev/null | grep -q .; then
    if command -v nmcli >/dev/null 2>&1; then
        ETH_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep "$AP_IFACE" | head -1 | cut -d: -f1)
        if [ -n "$ETH_CON" ]; then
            nmcli con mod "$ETH_CON" ipv4.never-default yes 2>/dev/null || true
            nmcli con up "$ETH_CON" 2>/dev/null || true
            log "NetworkManager: $AP_IFACE ($ETH_CON) set to never-default"
        fi
    fi
    # Immediate fix: delete the bad default route (covers dhcpcd and other cases)
    ip route del default dev "$AP_IFACE" 2>/dev/null || true
    log "Removed default route via $AP_IFACE (no internet on that interface)"
fi

# ---- Check if .env already exists and is valid ----

if [ -f "$ENV_FILE" ]; then
    load_env "$ENV_FILE"
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
    # Restart services that depend on the node number/IP
    # mesh-fix.sh configures br0 with MESH_IP, app services bind to it
    RESTART_SERVICES=true
fi

# ---- Generate .env from template ----

log "Generating .env for node $NODE_NUM..."

cp "$ENV_TEMPLATE" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# Calculate mesh IP: 192.168.199.(100 + node_number)
if ! MESH_IP="$(mesh_ip_for_node "$NODE_NUM")"; then
    log "Error: invalid node number $NODE_NUM"
    exit 1
fi

# Set node-specific values
set_env_value "$ENV_FILE" "PI_NUMBER" "$NODE_NUM"
set_env_value "$ENV_FILE" "MESH_IP" "$MESH_IP"

# Inject secrets from .secrets file (preserved by build-image.sh)
if [ -f "$SECRETS_FILE" ]; then
    log "Injecting secrets from .secrets..."
    # Whitelist of allowed secret keys — prevents .secrets from injecting
    # arbitrary env vars into the node config (defense in depth)
    ALLOWED_KEYS="IRC_LINK_PASSWORD TAILSCALE_AUTH_KEY HF_TOKEN WIFI_SSID WIFI_PASSWORD SIGNALEMENT_EMAIL LEGAL_OPERATOR_INFO LEGAL_RGPD_EMAIL COUNTRY_CODE"
    while IFS= read -r line; do
        # Skip comments and empty lines
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        # Skip malformed lines (must contain =)
        [[ "$line" != *=* ]] && continue
        # Split on first = only (preserves = in values like base64 tokens)
        key="${line%%=*}"
        value="${line#*=}"
        [[ -z "$key" ]] && continue
        # Only inject whitelisted keys
        allowed=false
        for k in $ALLOWED_KEYS; do
            [[ "$key" = "$k" ]] && { allowed=true; break; }
        done
        if [ "$allowed" = false ]; then
            log "Skipping unknown secret key: $key"
            continue
        fi
        # Use set_env_value — no escaping needed
        if ! set_env_value "$ENV_FILE" "$key" "$value"; then
            log "ERROR: Failed to inject secret key $key"
        fi
    done < "$SECRETS_FILE"
    log "Secrets injected"
fi

log "Config: PI_NUMBER=$NODE_NUM MESH_IP=$MESH_IP"

# ---- Tailscale setup (if auth key present and not yet connected) ----

load_env "$ENV_FILE"
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

# ---- Regenerate dnsmasq config (DHCP pool depends on node number) ----

log "Generating dnsmasq.conf for node $NODE_NUM..."
generate_dnsmasq_conf "$NIGHTWATCH_DIR/dnsmasq/dnsmasq.conf" "$NODE_NUM" "$MESH_IP"

# ---- Restart services if node number changed ----

if [ "$RESTART_SERVICES" = true ]; then
    log "Node number changed — restarting mesh and app services..."
    systemctl restart nightwatch-mesh.service 2>/dev/null || true
    sleep 5
    systemctl restart nightwatch-app.service 2>/dev/null || true
    log "Services restarted with new config"
fi

log "Node configuration complete"
