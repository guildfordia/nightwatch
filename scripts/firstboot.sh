#!/bin/bash
# Nightwatch — First boot autonomous setup
# This script runs ONCE on the Pi's first boot, then disables itself.
#
# It expects the project to be at /opt/nightwatch (or path in /etc/nightwatch.conf)
# and a valid .env to be present with this node's configuration (passwords baked in).
#
# What it does:
#   1. Wait for network (to apt install)
#   2. Install all system dependencies
#   3. Install app services (ngircd, nginx)
#   4. Load batman-adv, disable system hostapd/dnsmasq
#   5. Configure dhcpcd + DNS (resolv.conf locked)
#   6. Install Tailscale (if TAILSCALE_AUTH_KEY set)
#   7. Setup distributed IRC config
#   8. Generate dnsmasq config
#   9. Install all systemd services (nodeconfig, mesh, discovery, app)
#  10. Verify irc-bridge binary
#  11. Start everything
#  11b. Resolve node number conflicts (MAC-based reassignment)
#  12. Disable this firstboot service
#
# Designed for the "flash and forget" workflow:
#   1. Flash Pi OS with Pi Imager (set hostname, SSH, WiFi, user)
#   2. Run prepare-sdcard.sh to bake project + secrets onto the card
#   3. Boot — this script does the rest, fully unattended

set -euo pipefail

# Read project path from /etc/nightwatch.conf
if [ -f /etc/nightwatch.conf ]; then
    # shellcheck source=/dev/null
    source /etc/nightwatch.conf
fi
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-/opt/nightwatch}"
LOG_FILE="/var/log/nightwatch-firstboot.log"
STAMP_FILE="$NIGHTWATCH_DIR/.firstboot-done"

# Redirect all output to log + console
exec > >(tee -a "$LOG_FILE") 2>&1

echo ""
echo "======================================"
echo "  Nightwatch First Boot Setup"
echo "  $(date)"
echo "======================================"
echo ""

# Set LED to heartbeat pattern to indicate setup is in progress
for led in /sys/class/leds/ACT /sys/class/leds/led0; do
    if [ -d "$led" ]; then
        echo "heartbeat" > "$led/trigger" 2>/dev/null || true
        break
    fi
done

# Skip if already completed
if [ -f "$STAMP_FILE" ]; then
    echo "[+] First boot already completed. Skipping."
    exit 0
fi

if [ ! -d "$NIGHTWATCH_DIR" ]; then
    echo "[-] Error: $NIGHTWATCH_DIR not found"
    echo "[-] The project must be copied to $NIGHTWATCH_DIR before first boot"
    exit 1
fi

cd "$NIGHTWATCH_DIR"

# If .env doesn't exist, run nodeconfig first to generate it (dynamic mode)
if [ ! -f ".env" ]; then
    echo "[+] No .env found — running nodeconfig for dynamic node assignment..."
    if [ -x scripts/nodeconfig.sh ]; then
        if ! scripts/nodeconfig.sh; then
            echo "[-] Error: nodeconfig.sh failed"
            exit 1
        fi
    else
        echo "[-] Error: .env not found and nodeconfig.sh not available"
        exit 1
    fi
fi

if [ ! -f ".env" ]; then
    echo "[-] Error: .env still not found after nodeconfig"
    exit 1
fi

# shellcheck source=scripts/common.sh
source "$NIGHTWATCH_DIR/scripts/common.sh"

load_env .env

# Detect the real user (not root) — prefer UID 1000 (the default non-root user on Pi OS)
REAL_USER=$(getent passwd 1000 2>/dev/null | cut -d: -f1 || true)
REAL_USER="${REAL_USER:-pi}"

echo "[+] Node: Pi #${PI_NUMBER:-?} — IP: ${MESH_IP:-?}"
echo "[+] User: $REAL_USER"
echo ""

# ---- Step 0: Ensure WiFi is configured ----
# Cloud-init on Raspberry Pi OS Bookworm may fail to create NetworkManager WiFi
# connections from network-config (missing cc_netplan_nm_patch module).
# Detect this and create the NM connection file as a fallback.
NM_DIR="/etc/NetworkManager/system-connections"
BOOT_DIR=""
[ -d /boot/firmware ] && BOOT_DIR=/boot/firmware
[ -z "$BOOT_DIR" ] && [ -d /boot ] && BOOT_DIR=/boot
NETCFG="${BOOT_DIR}/network-config"

if [ -d "$NM_DIR" ] && [ -f "$NETCFG" ] && grep -q 'wifis:' "$NETCFG"; then
    if ! ls "$NM_DIR"/*.nmconnection 2>/dev/null | grep -q .; then
        WIFI_SSID=$(grep -A5 'access-points:' "$NETCFG" | sed -n 's/^[[:space:]]*"\([^"]*\)":.*/\1/p' | head -1)
        WIFI_PSK=$(grep -A10 'access-points:' "$NETCFG" | sed -n 's/^[[:space:]]*password:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\1/p' | head -1)
        if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PSK" ]; then
            WIFI_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "fb-wifi-$(date +%s)")
            cat > "$NM_DIR/$WIFI_SSID.nmconnection" << WIFIEOF
[connection]
id=$WIFI_SSID
uuid=$WIFI_UUID
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
WIFIEOF
            chmod 600 "$NM_DIR/$WIFI_SSID.nmconnection"
            nmcli connection reload 2>/dev/null || true
            nmcli connection up "$WIFI_SSID" 2>/dev/null || true
            echo "[+] Created NM WiFi connection for '$WIFI_SSID' (cloud-init fallback)"
            sleep 10
        fi
    fi
fi

# ---- Step 1: Wait for network ----

echo "[1/12] Waiting for network..."
TRIES=0
MAX_TRIES=30
while ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge "$MAX_TRIES" ]; then
        echo "[-] No internet after ${MAX_TRIES} attempts."
        echo "[-] Connect Ethernet or configure WiFi, then run: sudo systemctl start nightwatch-firstboot"
        exit 1
    fi
    echo "  Waiting... ($TRIES/$MAX_TRIES)"
    sleep 5
done
echo "[+] Network is up"

# ---- Step 1b: Sync clock (Pi has no hardware RTC) ----

echo "[1b/12] Syncing system clock..."
# Without correct time, apt signature verification fails ("Not live until ...")
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-ntp true 2>/dev/null || true
    # Wait up to 30s for NTP sync
    for i in $(seq 1 15); do
        if timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -q "yes"; then
            break
        fi
        sleep 2
    done
fi
# Fallback: fetch time from HTTP header if NTP didn't work
# Check if clock is behind the build date of this script (Pi has no RTC)
SCRIPT_YEAR=$(date -r "$NIGHTWATCH_DIR/scripts/firstboot.sh" +%Y 2>/dev/null || echo "2025")
if [ "$(date +%Y)" -lt "$SCRIPT_YEAR" ]; then
    HTTP_DATE=$(curl -sI --max-time 10 http://deb.debian.org 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //')
    if [ -n "$HTTP_DATE" ] && date -d "$HTTP_DATE" >/dev/null 2>&1; then
        date -s "$HTTP_DATE" 2>/dev/null || true
        echo "[+] Clock set from HTTP: $(date)"
    else
        echo "[!] Warning: could not sync clock — apt may fail"
    fi
else
    echo "[+] Clock OK: $(date)"
fi

# ---- Step 1c: Ensure SSH host keys exist ----
# build-image.sh deletes SSH keys for cloning; regenerate if missing
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    echo "[1c/12] Regenerating SSH host keys..."
    ssh-keygen -A >/dev/null 2>&1 || true
    systemctl restart sshd 2>/dev/null || true
    echo "[+] SSH host keys regenerated"
fi

# ---- Step 2: Install system packages ----

echo ""
echo "[2/12] Installing system packages..."
APT_DELAY=5
for attempt in 1 2 3; do
    if apt-get update -qq; then
        break
    fi
    echo "[!] apt-get update failed (attempt $attempt/3), retrying in ${APT_DELAY}s..."
    sleep "$APT_DELAY"
    APT_DELAY=$((APT_DELAY * 2))
done
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    ngircd \
    nginx \
    batctl \
    bridge-utils \
    dnsmasq \
    iproute2 \
    iw \
    wireless-tools \
    net-tools \
    wpasupplicant \
    iptables \
    curl \
    git \
    fping \
    netcat-openbsd \
    socat \
    sshpass \
    firmware-atheros
echo "[+] System packages installed"

# Disable system dnsmasq — we start our own instance on br0 via mesh-fix.sh
systemctl disable dnsmasq 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# ---- Step 3: Configure native services ----

echo ""
echo "[3/12] Configuring native services..."

# Stop and disable default services
systemctl stop ngircd 2>/dev/null || true
systemctl disable ngircd 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

# Remove default nginx config
rm -f /etc/nginx/sites-enabled/default

# Symlink Nightwatch configs
ln -sf "$NIGHTWATCH_DIR/nginx/nginx.conf" /etc/nginx/conf.d/nightwatch.conf
rm -rf /usr/share/nginx/html
ln -sf "$NIGHTWATCH_DIR/html" /usr/share/nginx/html
# Generate self-signed certs for captive portal HTTPS redirect (if missing)
CERT_DIR="$NIGHTWATCH_DIR/nginx/certs"
if [ ! -f "$CERT_DIR/captive.crt" ] || [ ! -f "$CERT_DIR/captive.key" ]; then
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CERT_DIR/captive.key" \
        -out "$CERT_DIR/captive.crt" \
        -subj "/CN=nightwatch.local" 2>/dev/null
    echo "[+] Self-signed TLS cert generated for captive portal"
fi
ln -sf "$CERT_DIR" /etc/nginx/certs
ln -sf "$NIGHTWATCH_DIR/ngircd/ngircd.conf" /etc/ngircd/ngircd.conf

# Create data directory for irc-bridge
mkdir -p "$NIGHTWATCH_DIR/irc-bridge-go/data"
chown "$REAL_USER:$REAL_USER" "$NIGHTWATCH_DIR/irc-bridge-go/data"

# Make irc-bridge binary executable
if [ -f "$NIGHTWATCH_DIR/irc-bridge-go/irc-bridge" ]; then
    chmod +x "$NIGHTWATCH_DIR/irc-bridge-go/irc-bridge"
fi

echo "[+] Native services configured"

# ---- Step 4: Setup batman-adv ----

echo ""
echo "[4/12] Setting up batman-adv..."
modprobe batman-adv || true
if ! grep -q "^batman-adv" /etc/modules 2>/dev/null; then
    echo "batman-adv" >> /etc/modules
fi
echo "[+] batman-adv version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'loads on boot')"

# Disable system services we don't need
systemctl disable hostapd 2>/dev/null || true
systemctl stop hostapd 2>/dev/null || true

# ---- Step 5: Configure network (dhcpcd + DNS) ----

echo ""
echo "[5/12] Configuring network routing..."

configure_network

# ---- Step 6: Install Tailscale ----

echo ""
echo "[6/12] Tailscale setup..."
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

if [ -n "$TAILSCALE_AUTH_KEY" ]; then
    if ! command -v tailscale >/dev/null 2>&1; then
        echo "[+] Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
        echo "[+] Tailscale installed"
    else
        echo "[+] Tailscale already installed"
    fi

    systemctl enable tailscaled
    systemctl start tailscaled

    # Join the tailnet unattended with the auth key (via file to avoid ps exposure)
    echo "[+] Joining tailnet with auth key..."
    TS_KEY_FILE=$(mktemp /tmp/nightwatch-ts-key.XXXXXX)
    chmod 600 "$TS_KEY_FILE"
    printf '%s' "$TAILSCALE_AUTH_KEY" > "$TS_KEY_FILE"
    tailscale up --auth-key="file:$TS_KEY_FILE" --accept-routes --accept-dns=false --hostname="$(hostname)" --reset
    rm -f "$TS_KEY_FILE"

    # Wait for connection
    sleep 3
    TAILSCALE_IP=$(tailscale ip --4 2>/dev/null || echo "pending")
    echo "[+] Tailscale connected: $TAILSCALE_IP"
else
    echo "[+] No TAILSCALE_AUTH_KEY set — skipping Tailscale"
fi

# ---- Step 7: Setup distributed IRC config ----

echo ""
echo "[7/12] Setting up distributed IRC..."
if [ -x scripts/setup-distributed-irc.sh ]; then
    cd "$NIGHTWATCH_DIR"
    scripts/setup-distributed-irc.sh
    echo "[+] IRC configuration generated"
else
    echo "[!] setup-distributed-irc.sh not found, skipping"
fi

# ---- Step 8: Generate dnsmasq config ----

echo ""
echo "[8/12] Generating dnsmasq config..."
NODE_NUM="${PI_NUMBER:-1}"
generate_dnsmasq_conf "$NIGHTWATCH_DIR/dnsmasq/dnsmasq.conf" "$NODE_NUM" "$MESH_IP"
DHCP_START=$((200 + (NODE_NUM - 1) * 5 + 1))
DHCP_END=$((200 + (NODE_NUM - 1) * 5 + 5))
echo "[+] dnsmasq.conf generated (DHCP: .${DHCP_START}-.${DHCP_END})"

# ---- Step 9: Install systemd services ----

echo ""
echo "[9/12] Installing systemd services..."

install_systemd_services "$NIGHTWATCH_DIR"

echo "[+] Services installed and enabled:"
echo "    - nightwatch-nodeconfig (generates config from hostname)"
echo "    - nightwatch-mesh (802.11s + batman-adv + bridge)"
echo "    - nightwatch-discovery (UDP broadcast node discovery)"
echo "    - nightwatch-docker (IRC + bridge + nginx orchestrator)"
echo "    - nightwatch-led (green LED readiness indicator)"
echo "    - nightwatch-debug (debug info collector)"

# ---- Step 10: Verify irc-bridge binary ----

echo ""
echo "[10/12] Verifying irc-bridge binary..."
cd "$NIGHTWATCH_DIR"
if [ -f "$NIGHTWATCH_DIR/irc-bridge-go/irc-bridge" ]; then
    echo "[+] irc-bridge binary found"
else
    echo "[!] Warning: irc-bridge binary not found at $NIGHTWATCH_DIR/irc-bridge-go/irc-bridge"
    echo "[!] The binary needs to be cross-compiled for ARM before deployment"
fi

# ---- Step 11: Start everything ----

echo ""
echo "[11/12] Starting mesh network..."
systemctl start nightwatch-mesh.service
sleep 5

echo "[+] Starting node discovery..."
systemctl start nightwatch-discovery.service 2>/dev/null || true

echo "[+] Starting native services..."
systemctl start ngircd
systemctl start nightwatch-bridge
systemctl start nginx
sleep 3
echo "[+] Services started"

echo "[+] Starting LED readiness indicator..."
systemctl start nightwatch-led.service 2>/dev/null || true

echo "[+] Starting debug info collector..."
systemctl start nightwatch-debug.service 2>/dev/null || true

# ---- Step 11b: Resolve node number conflicts ----
# On first boot, nodeconfig runs before other nodes have their mesh up,
# so every node picks #1. Now that mesh is live, use deterministic
# MAC-based sorting to assign unique numbers (same algorithm as
# nodeconfig.sh scan_mesh).

echo ""
echo "[11b/12] Checking for node number conflicts..."

PEER_WAIT=0
PEER_COUNT=0
# Skip peer wait entirely if bat0 isn't up (solo deployment, no mesh dongle, etc.)
if [ -d /sys/class/net/bat0 ]; then
    while [ "$PEER_WAIT" -lt 120 ]; do
        PEER_COUNT=$(batctl meshif bat0 n 2>/dev/null | tail -n +3 | grep -c . || true)
        PEER_COUNT=${PEER_COUNT:-0}
        if [ "$PEER_COUNT" -gt 0 ]; then
            break
        fi
        sleep 10
        PEER_WAIT=$((PEER_WAIT + 10))
    done
else
    echo "[+] bat0 not found — skipping peer discovery wait"
fi

if [ "$PEER_COUNT" -gt 0 ]; then
    echo "[+] Mesh has $PEER_COUNT neighbor(s) — verifying node assignment..."

    # Determine correct node number using MAC-based sorting
    OUR_MAC=$(cat "/sys/class/net/${MESH_IFACE:-wlan1}/address" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
    NEIGHBOR_MACS=$(batctl meshif bat0 n 2>/dev/null | tail -n +3 | awk '{print $2}' | tr '[:upper:]' '[:lower:]' | sort || true)

    if [ -n "$OUR_MAC" ] && [ -n "$NEIGHBOR_MACS" ]; then
        ALL_MACS=$(printf '%s\n%s' "$OUR_MAC" "$NEIGHBOR_MACS" | sort)
        OUR_POSITION=1
        while IFS= read -r mac; do
            if [ "$mac" = "$OUR_MAC" ]; then
                break
            fi
            OUR_POSITION=$((OUR_POSITION + 1))
        done <<< "$ALL_MACS"

        CURRENT_NUM="${PI_NUMBER:-1}"
        if [ "$OUR_POSITION" != "$CURRENT_NUM" ]; then
            echo "[!] Conflict: currently #$CURRENT_NUM, should be #$OUR_POSITION (MAC sort)"
            echo "[+] Reassigning to node #$OUR_POSITION..."
            # Write correct number — nodeconfig detects the change and
            # regenerates .env, ngircd.conf, dnsmasq.conf, hostname, restarts services
            echo "$OUR_POSITION" > "$NIGHTWATCH_DIR/.node-number"
            "$NIGHTWATCH_DIR/scripts/nodeconfig.sh"
            # Reload .env so stamp file and summary use updated values
            load_env "$NIGHTWATCH_DIR/.env"
            echo "[+] Reassigned to Pi #${PI_NUMBER} (${MESH_IP})"
        else
            echo "[+] Node #$CURRENT_NUM confirmed — no conflict"
        fi
    fi
else
    echo "[+] Solo node (no mesh peers yet) — keeping node #${PI_NUMBER:-1}"
fi

# Regenerate dnsmasq config with final node number (may have changed in 11b)
NODE_NUM="${PI_NUMBER:-1}"
generate_dnsmasq_conf "$NIGHTWATCH_DIR/dnsmasq/dnsmasq.conf" "$NODE_NUM" "$MESH_IP"

# ---- Step 12: Mark complete & disable firstboot ----

echo ""
echo "[12/12] Finalizing..."

# Create stamp file
date > "$STAMP_FILE"
echo "Pi #${PI_NUMBER} — ${MESH_IP}" >> "$STAMP_FILE"

# Disable firstboot service (we don't need it again)
systemctl disable nightwatch-firstboot.service 2>/dev/null || true

# Get Tailscale IP if available
TS_IP=""
if command -v tailscale >/dev/null 2>&1; then
    TS_IP=$(tailscale ip --4 2>/dev/null || echo "")
fi

echo ""
echo "======================================"
echo "  Nightwatch First Boot Complete!"
echo "  Node:       Pi #${PI_NUMBER}"
echo "  Mesh IP:    ${MESH_IP}"
echo "  AP SSID:    ${WIFI_SSID:-Nightwatch}"
if [ -n "$TS_IP" ]; then
echo "  Tailscale:  ${TS_IP}"
fi
echo ""
echo "  Web UI:     http://${MESH_IP%/*}"
echo "  Log:        $LOG_FILE"
echo "======================================"
