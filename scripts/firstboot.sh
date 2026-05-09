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
#   3. Install app services (ngircd, nginx, irc-bridge)
#   4. Load batman-adv, disable system hostapd/dnsmasq (mesh-fix.sh manages them)
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

# Boot-partition log — readable on macOS (FAT32) for debugging
BOOT_LOG=""
for _bdir in /boot/firmware /boot; do
    if [ -d "$_bdir" ] && mount | grep -q "$_bdir.*vfat"; then
        BOOT_LOG="$_bdir/nightwatch-firstboot.log"
        break
    fi
done

# Redirect all output to log + console (+ boot partition if available)
if [ -n "$BOOT_LOG" ]; then
    exec > >(tee -a "$LOG_FILE" "$BOOT_LOG") 2>&1
else
    exec > >(tee -a "$LOG_FILE") 2>&1
fi

echo ""
echo "======================================"
echo "  Nightwatch First Boot Setup"
echo "  $(date)"
echo "======================================"
echo ""

# Find onboard LED for status indication
LED_PATH=""
for led in /sys/class/leds/ACT /sys/class/leds/led0; do
    if [ -d "$led" ]; then
        LED_PATH="$led"
        echo "heartbeat" > "$led/trigger" 2>/dev/null || true
        break
    fi
done

# On any error: set LED to fast blink and log the failure.
# IMPORTANT: always mark firstboot as done (even on failure) so the service
# is disabled and never blocks boot again. The node can be fixed manually.
firstboot_fail() {
    echo ""
    echo "[-] FIRSTBOOT FAILED: $1"
    echo "[-] Check log: $LOG_FILE"
    [ -n "$BOOT_LOG" ] && echo "[-] Boot partition log: $BOOT_LOG"
    # Mark as done to prevent boot loops — a failed firstboot that blocks
    # every boot is worse than a failed firstboot you can fix via SSH.
    date > "$STAMP_FILE" 2>/dev/null || true
    echo "FAILED: $1" >> "$STAMP_FILE" 2>/dev/null || true
    systemctl disable nightwatch-firstboot.service 2>/dev/null || true
    if [ -n "$LED_PATH" ]; then
        echo "timer" > "$LED_PATH/trigger" 2>/dev/null || true
        echo 100 > "$LED_PATH/delay_on" 2>/dev/null || true
        echo 100 > "$LED_PATH/delay_off" 2>/dev/null || true
    fi
    exit 1
}
trap 'firstboot_fail "unexpected error at line $LINENO"' ERR

# Global timeout: if firstboot takes more than 15 minutes, something is
# seriously wrong. Kill it so the system can finish booting. The failure
# handler will mark it as done to prevent infinite boot loops.
FIRSTBOOT_TIMEOUT=900
( sleep "$FIRSTBOOT_TIMEOUT"; echo "[-] TIMEOUT: firstboot exceeded ${FIRSTBOOT_TIMEOUT}s"; kill -TERM $$ 2>/dev/null ) &
TIMEOUT_PID=$!
trap 'kill "$TIMEOUT_PID" 2>/dev/null || true; firstboot_fail "unexpected error at line $LINENO"' ERR
trap 'kill "$TIMEOUT_PID" 2>/dev/null || true' EXIT

# Skip if already completed
if [ -f "$STAMP_FILE" ]; then
    echo "[+] First boot already completed. Skipping."
    exit 0
fi

if [ ! -d "$NIGHTWATCH_DIR" ]; then
    firstboot_fail "$NIGHTWATCH_DIR not found — project must be copied before first boot"
fi

cd "$NIGHTWATCH_DIR"

# If .env doesn't exist, run nodeconfig first to generate it (dynamic mode)
if [ ! -f ".env" ]; then
    echo "[+] No .env found — running nodeconfig for dynamic node assignment..."
    if [ -x scripts/nodeconfig.sh ]; then
        if ! scripts/nodeconfig.sh; then
            firstboot_fail "nodeconfig.sh failed"
        fi
    else
        firstboot_fail ".env not found and nodeconfig.sh not available"
    fi
fi

if [ ! -f ".env" ]; then
    firstboot_fail ".env still not found after nodeconfig"
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
# Check if key packages are already installed — if so, internet is optional.
# Pre-baked golden images (build-image.sh) ship with everything; this path
# can finish firstboot offline.
PKGS_INSTALLED=true
for pkg in ngircd nginx batctl dnsmasq socat; do
    if ! command -v "$pkg" >/dev/null 2>&1 && ! dpkg -s "$pkg" >/dev/null 2>&1; then
        PKGS_INSTALLED=false
        break
    fi
done

# When packages are pre-installed, internet is only useful for Tailscale auth
# and HTTP clock sync — both quickly skippable. Cut the wait so cloned images
# don't burn 2 min waiting for a network they don't need.
if $PKGS_INSTALLED; then
    MAX_TRIES=6   # 6 × 5s = 30s
    echo "[+] Packages pre-baked — short network probe (30s) before going offline-friendly"
else
    MAX_TRIES=30  # 30 × 5s = 150s, the slow path
fi

TRIES=0
while ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; do
    TRIES=$((TRIES + 1))
    if [ "$TRIES" -ge "$MAX_TRIES" ]; then
        if $PKGS_INSTALLED; then
            echo "[!] No internet after ${MAX_TRIES} attempts — packages pre-baked, continuing offline"
            break
        else
            firstboot_fail "No internet after ${MAX_TRIES} attempts ($((MAX_TRIES * 5))s). Connect Ethernet or fix WiFi, then: sudo systemctl start nightwatch-firstboot"
        fi
    fi
    echo "  Waiting... ($TRIES/$MAX_TRIES)"
    sleep 5
done
if [ "$TRIES" -lt "$MAX_TRIES" ]; then
    echo "[+] Network is up"
fi

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
SCRIPT_YEAR=$(date -r "$NIGHTWATCH_DIR/scripts/firstboot.sh" +%Y 2>/dev/null \
    || stat -c %Y "$NIGHTWATCH_DIR/scripts/firstboot.sh" 2>/dev/null | xargs -I{} date -d @{} +%Y 2>/dev/null \
    || echo "2099")
if [ "$(date +%Y)" -lt "$SCRIPT_YEAR" ]; then
    HTTP_DATE=$(curl -sI --max-time 10 http://deb.debian.org 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //' | tr -d '\r')
    # Validate: must look like an HTTP-date (e.g. "Mon, 17 Mar 2025 12:00:00 GMT")
    # Reject empty, overly long, or non-date strings to prevent injection
    if [ -n "$HTTP_DATE" ] && [ "${#HTTP_DATE}" -lt 80 ] && \
       [[ "$HTTP_DATE" =~ ^[A-Za-z]{3},\ [0-9]{2}\ [A-Za-z]{3}\ [0-9]{4}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ GMT$ ]] && \
       date -d "$HTTP_DATE" >/dev/null 2>&1; then
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

# Pre-baked golden images (built via scripts/build-image.sh) already have
# every package installed; in that case skip the entire apt cycle. This
# drops cold-boot time-to-mesh from 6-12 min to ~3 min and removes the
# internet-at-firstboot requirement entirely on the cloned-image path
# (CdC §3.4 #5: ≤ 15 min budget — we keep the headroom for the
# prepare-sdcard.sh path that ships a vanilla Pi OS).
REQUIRED_PKGS=(
    ngircd nginx batctl bridge-utils dnsmasq iproute2 iw wireless-tools
    net-tools wpasupplicant iptables ebtables iputils-arping curl git
    fping netcat-openbsd socat sshpass usbutils firmware-atheros hostapd
)

MISSING_PKGS=()
for pkg in "${REQUIRED_PKGS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
    echo "[+] All packages already present (pre-baked image) — skipping apt"
else
    echo "[+] Installing ${#MISSING_PKGS[@]} missing package(s): ${MISSING_PKGS[*]}"
    APT_DELAY=5
    for attempt in 1 2 3; do
        if apt-get update -qq; then
            break
        fi
        echo "[!] apt-get update failed (attempt $attempt/3), retrying in ${APT_DELAY}s..."
        sleep "$APT_DELAY"
        APT_DELAY=$((APT_DELAY * 2))
    done
    if ! DEBIAN_FRONTEND=noninteractive timeout 600 apt-get install -y -qq \
        "${MISSING_PKGS[@]}"; then
        firstboot_fail "apt-get install failed or timed out (10 min limit)"
    fi
    echo "[+] System packages installed"
fi

# Disable system dnsmasq — we start our own instance on br0 via mesh-fix.sh
systemctl disable dnsmasq 2>/dev/null || true
systemctl stop dnsmasq 2>/dev/null || true

# ---- Step 3: Configure native services ----

echo ""
echo "[3/12] Configuring native services..."

# Stop and disable default services (nightwatch-app starts them)
systemctl stop ngircd 2>/dev/null || true
systemctl disable ngircd 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

# Override ngircd + nginx to always restart (default is on-failure which misses
# clean SIGTERM exits — required by CdC §3.4 #3a: kill → restart < 60 s).
mkdir -p /etc/systemd/system/ngircd.service.d /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/ngircd.service.d/restart.conf <<'OVERRIDE'
[Service]
Restart=always
RestartSec=5
OVERRIDE
cat > /etc/systemd/system/nginx.service.d/restart.conf <<'OVERRIDE'
[Service]
Restart=always
RestartSec=5
OVERRIDE
systemctl daemon-reload

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

# Disable system hostapd — mesh-fix.sh starts hostapd manually with our config
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
[ "$DHCP_START" -gt 254 ] && DHCP_START=254
[ "$DHCP_END" -gt 254 ] && DHCP_END=254
echo "[+] dnsmasq.conf generated (DHCP: .${DHCP_START}-.${DHCP_END})"

# ---- Step 8b: Generate hostapd config ----

echo ""
echo "[8b/12] Generating hostapd config (WiFi AP with 802.11r)..."
mkdir -p "$NIGHTWATCH_DIR/hostapd"
AP_IFACE_VAL=$(grep '^AP_IFACE=' "$NIGHTWATCH_DIR/.env" 2>/dev/null | cut -d= -f2- || echo "wlan2")
AP_CHANNEL_VAL=$(grep '^AP_CHANNEL=' "$NIGHTWATCH_DIR/.env" 2>/dev/null | cut -d= -f2- || echo "0")
AP_BSSID_VAL=$(grep '^AP_BSSID=' "$NIGHTWATCH_DIR/.env" 2>/dev/null | cut -d= -f2- || echo "02:00:4E:57:00:01")
WIFI_SSID_VAL=$(grep '^WIFI_SSID=' "$NIGHTWATCH_DIR/.env" 2>/dev/null | cut -d= -f2- || echo "Nightwatch")
WIFI_PASSWORD_VAL=$(grep '^WIFI_PASSWORD=' "$NIGHTWATCH_DIR/.env" 2>/dev/null | cut -d= -f2- || echo "Nightwatch")
generate_hostapd_conf "$NIGHTWATCH_DIR/hostapd/hostapd.conf" \
    "$AP_IFACE_VAL" "br0" \
    "$WIFI_SSID_VAL" "$WIFI_PASSWORD_VAL" \
    "$AP_CHANNEL_VAL" "$AP_BSSID_VAL"
echo "[+] hostapd.conf generated (SSID: $WIFI_SSID_VAL, ch $AP_CHANNEL_VAL)"

# ---- Step 9: Install systemd services ----

echo ""
echo "[9/12] Installing systemd services..."

install_systemd_services "$NIGHTWATCH_DIR"

echo "[+] Services installed and enabled:"
echo "    - nightwatch-nodeconfig (generates config from hostname)"
echo "    - nightwatch-mesh (802.11s + batman-adv + bridge)"
echo "    - nightwatch-discovery (UDP broadcast node discovery)"
echo "    - nightwatch-app (IRC + bridge + nginx orchestrator)"
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

# ---- Step 11: Services will start after firstboot completes ----
# NOTE: Do NOT use 'systemctl start' here. Firstboot runs as a oneshot
# service during boot. Starting other services synchronously creates a
# deadlock: those services wait for multi-user.target, which waits for
# firstboot to finish. All services are already enabled (step 9) and
# will start automatically when firstboot completes and systemd reaches
# multi-user.target.

echo ""
echo "[11/12] Services are enabled — they will start after firstboot completes"
echo "    Enabled: nightwatch-mesh, nightwatch-app, nightwatch-discovery,"
echo "             nightwatch-bridge, nightwatch-led, nightwatch-debug"

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

# Reboot so all enabled services start cleanly.
# Without this the Pi sits idle after firstboot with no visual feedback.
echo ""
echo "[+] Rebooting to start Nightwatch services..."
shutdown -r +1 "Nightwatch: firstboot complete — rebooting to start services" &
