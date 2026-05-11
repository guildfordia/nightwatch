#!/bin/bash
# Nightwatch — Shared helper library
#
# Sourced by all scripts that need common patterns:
#   - .env file loading
#   - ngircd.conf base template generation
#   - Mesh IP calculation
#   - Network configuration
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/common.sh"

# Maximum number of nodes in the mesh.
#
# Architectural ceiling for the /24 subnet 192.168.199.0/24:
#   28 nodes × 8 DHCP IPs/node = 224 baux, fits in /24 with .101-.128
#   reserved for static node IPs, .1 anchor, .255 broadcast, and
#   .98-.100 / .129-.130 / .249-.254 left as operational gaps.
#
# For 30+ nodes you must migrate to /23 (192.168.198.0/23) — see
# docs/capacity-planning.md. That is a netmask + IP-scheme change,
# not a constant bump.
#
# Default 20 matches the CdC §3.3 design figure. Bump up to 28 for
# a single-event capacity push without changing the subnet. Going
# higher requires the subnet migration.
MAX_NODES="${MAX_NODES:-20}"

# load_env <path> — loads .env file with allexport, exits on missing file
load_env() {
    local env_file="$1"
    if [ ! -f "$env_file" ]; then
        echo "[-] Error: $env_file not found"
        exit 1
    fi
    # Temporarily disable nounset — .env values may contain $literal text
    # that bash would try to expand as variables (e.g. passwords with $)
    # Use subshell-free approach: always restore nounset even if source fails
    set +o nounset
    set -o allexport
    # shellcheck source=/dev/null
    local _load_env_rc=0
    source "$env_file" || _load_env_rc=$?
    set +o allexport
    set -o nounset
    return $_load_env_rc
}

# generate_ngircd_base_conf <conf_path> <server_name> <node_num>
# Writes the base ngircd.conf template (Global, Limits, Options, Channel).
# Callers append [Server] peer blocks or comments after this.
generate_ngircd_base_conf() {
    local conf_path="$1"
    local server_name="$2"
    local node_num="$3"

    mkdir -p "$(dirname "$conf_path")"

    cat > "$conf_path" << EOF
[Global]
Name = $server_name
AdminInfo1 = Nightwatch IRC Server - Node $node_num
AdminInfo2 = Mesh Network
AdminEMail = admin@nightwatch.local
Listen = 0.0.0.0
MotdPhrase = Nightwatch mesh node $node_num
ServerUID = irc
ServerGID = irc

[Limits]
MaxConnections = 150
MaxConnectionsIP = 25
MaxJoins = 3
MaxNickLength = 12
PingTimeout = 120
PongTimeout = 30
IdleTimeout = 0
MaxChannelNameLength = 15
MaxTopicLength = 80
MaxAwayLen = 40
MaxListSize = 100

[Options]
RequireAuthPing = no
PAM = no

[Channel]
name = #nightwatch
topic = Nightwatch Chat
modes = +nt
maxusers = 100
EOF
}

# mesh_ip_for_node <n> — echoes 192.168.199.(100+n)
# Validates that n is within 1..MAX_NODES.
mesh_ip_for_node() {
    local n="$1"
    if ! [[ "$n" =~ ^[0-9]+$ ]]; then
        echo "mesh_ip_for_node: '$n' is not a number" >&2
        return 1
    fi
    if [ "$n" -lt 1 ] || [ "$n" -gt "$MAX_NODES" ]; then
        echo "mesh_ip_for_node: node $n out of range (1-$MAX_NODES)" >&2
        return 1
    fi
    echo "192.168.199.$((100 + n))"
}

# generate_dnsmasq_conf <conf_path> <node_num> <mesh_ip>
# Writes the dnsmasq.conf template for captive portal + DHCP. Every node
# also serves a DHCP lease on eth0 (10.0.0.0/24) for the Mac sound-bridge
# (CdC §3.4 #4 plug-and-play). dnsmasq's bind-interfaces makes the eth0
# listener inert until eth0 has the 10.0.0.1/24 address mesh-fix.sh sets up.
generate_dnsmasq_conf() {
    local conf_path="$1"
    local node_num="$2"
    local mesh_ip="${3%/*}"  # strip CIDR suffix if present

    # Validate node_num is within range (prevents invalid DHCP ranges)
    if ! [[ "$node_num" =~ ^[0-9]+$ ]] || [ "$node_num" -lt 1 ] || [ "$node_num" -gt "$MAX_NODES" ]; then
        echo "generate_dnsmasq_conf: node_num $node_num out of range (1-$MAX_NODES)" >&2
        return 1
    fi

    # DHCP pool layout — 8 IPs per node, supporting up to 20 nodes fleet-wide.
    # Cohérent avec §3.4 #11 du CdC (max_num_sta=8) et §3.3 (capacité 20 nœuds).
    # The node IPs themselves live at .101-.120, the anchor service IP at .1, so
    # the visitor pool layout is:
    #   Nodes 1-16  → primary range  .121 to .248  (16 × 8 = 128 IPs)
    #   Nodes 17-20 → secondary range .2   to .33  (4 × 8 = 32 IPs)
    # The .34-.100 and .249-.254 gaps are left free for operational use.
    local dhcp_start dhcp_end
    if [ "$node_num" -le 16 ]; then
        dhcp_start=$(( (node_num - 1) * 8 + 121 ))
        dhcp_end=$(( (node_num - 1) * 8 + 128 ))
    else
        dhcp_start=$(( (node_num - 17) * 8 + 2 ))
        dhcp_end=$(( (node_num - 17) * 8 + 9 ))
    fi

    mkdir -p "$(dirname "$conf_path")"

    cat > "$conf_path" << DNSEOF
# Nightwatch dnsmasq — DHCP + captive portal DNS for WiFi clients
# Auto-generated — do not edit manually

# Only listen on the mesh bridge
# Only listen on the mesh bridge
interface=br0
bind-interfaces

# DHCP range for WiFi clients — each node owns 8 IPs (matching max_num_sta=8).
# Batman-adv bridges all routers, so DHCP broadcasts reach every node's dnsmasq.
# Non-overlapping ranges prevent duplicate leases. Layout:
#   nodes 1-16  → .121 to .248 (primary range)
#   nodes 17-20 → .2   to .33  (secondary range)
#
# Lease time: 1h is the default and matches a quiet deployment where
# the same visitor keeps the same IP for the whole visit. For event-
# style use (vernissage with 100 + people churning through over a few
# hours), set NIGHTWATCH_DHCP_LEASE in /etc/default/nightwatch to a
# shorter value like "10m" — phones that leave free their IP slot
# faster, raising the effective fleet capacity above the per-node
# 8-IP cap (the cap stays, but the rotation accelerates).
dhcp-range=192.168.199.${dhcp_start},192.168.199.${dhcp_end},255.255.255.0,${NIGHTWATCH_DHCP_LEASE:-1h}

# Tell clients to use this node as gateway and DNS
dhcp-option=3,${mesh_ip}
dhcp-option=6,${mesh_ip}

# RFC 8910 Captive Portal API — tells Android 11+ and modern devices
# where to find the captive portal API (RFC 8908 JSON endpoint).
# This triggers "Sign in to network" instead of "no internet".
dhcp-option=114,http://${mesh_ip}/api/captive

# Redirect ALL DNS to this node
# Every domain resolves to the local Pi so any URL loads the chat page.
# Users type http://chat.nightwatch or the node IP in their browser.
address=/#/${mesh_ip}

# Don't read /etc/resolv.conf (we handle all DNS ourselves)
no-resolv

# Don't poll /etc/resolv.conf for changes
no-poll

# Log DHCP leases (useful for debugging)
log-dhcp

# PID file for mesh-fix.sh to manage
pid-file=/var/run/dnsmasq-nightwatch.pid
DNSEOF

    # CdC §3.4 #4 — every node serves a DHCP lease on eth0 (10.0.0.0/24)
    # so a Mac running nightwatch-sound can be plugged into any Pi and
    # reach 192.168.199.1. dnsmasq's bind-interfaces only binds when eth0
    # has the configured address (set by mesh-fix.sh), so this block is
    # inert on nodes that have nothing on eth0.
    cat >> "$conf_path" << 'SOUNDEOF'

# ── Sound-bridge subnet (eth0, CdC §3.4 #4) ──
interface=eth0
# Reserve .10-.50: leaves .1 (Pi) and the high range free for static
# overrides if the operator pins a specific Mac. Tag the range so the
# eth0-specific gateway/DNS options below override the br0 globals.
dhcp-range=set:eth,10.0.0.10,10.0.0.50,255.255.255.0,1h
dhcp-option=tag:eth,3,10.0.0.1
dhcp-option=tag:eth,6,10.0.0.1
SOUNDEOF
}

# generate_hostapd_conf <conf_path> <ap_iface> <br_iface> <ssid> <password> <channel> <bssid>
# Writes the hostapd.conf for WiFi AP with 802.11r (Fast Transition).
# Each node uses its dongle's hardware BSSID (unique per node), all with the
# same SSID — phones see multiple "Nightwatch" APs and switch to the strongest.
# The <bssid> arg is currently unused (the bssid= line is commented out below).
generate_hostapd_conf() {
    local conf_path="$1"
    local ap_iface="$2"
    local br_iface="$3"
    # Validate password length (WPA2-PSK requires 8-63 characters)
    if [ ${#5} -lt 8 ] || [ ${#5} -gt 63 ]; then
        echo "generate_hostapd_conf: WiFi password must be 8-63 characters (got ${#5})" >&2
        return 1
    fi
    local ssid="$4"
    local password="$5"
    local channel="${6:-6}"
    local bssid="${7:-02:00:4E:57:00:01}"
    # CdC §6.1 — pin hostapd to the deployment country so 2.4 GHz channels
    # and EIRP stay inside the local regulatory envelope (FR/ARCEP ≤ 100 mW).
    local country_code="${COUNTRY_CODE:-FR}"

    mkdir -p "$(dirname "$conf_path")"

    cat > "$conf_path" << HAPEOF
# Nightwatch hostapd — WiFi AP with 802.11r Fast Transition
# Auto-generated — do not edit manually

interface=$ap_iface
bridge=$br_iface
driver=nl80211

# Regulatory domain (CdC §6.1)
country_code=$country_code
ieee80211d=1

# WiFi settings
ssid=$ssid
channel=$channel
hw_mode=g
ieee80211n=1
HAPEOF

    # If channel=0, hostapd runs ACS (Automatic Channel Selection) at startup.
    # Restrict ACS to channels 1 and 6 — the only non-overlap 2.4 GHz channels
    # available for visitor APs (channel 11 is reserved fleet-wide for the mesh,
    # see §3.3 of the cahier des charges). If the operator pinned an explicit
    # AP_CHANNEL (1 or 6), we skip chanlist entirely.
    if [ "$channel" = "0" ]; then
        cat >> "$conf_path" << 'HAPACS'
chanlist=1 6
HAPACS
    fi

    cat >> "$conf_path" << HAPEOF

# AR9271 firmware becomes unstable past 12-15 stations and crashes the
# driver, triggering the watchdog cycle. Cap explicitly at 8 — hostapd
# refuses associations beyond this with a clean reason code rather than
# letting the radio crash. Cohérent avec le critère §3.4 #11 du CdC.
max_num_sta=8

# Each node broadcasts the same SSID with its dongle's own hardware BSSID
# (unique per node). Phones see multiple APs and pick the strongest.
# A shared BSSID was tried (one virtual AP across the fleet, seamless L1
# handover) but Samsung refused to auto-connect when the BSSID differed
# from the original association. Leaving bssid= commented lets hostapd use
# the dongle MAC, which is what we ship.
# bssid=$bssid

# WPA2-PSK + 802.11r Fast Transition
# FT-PSK enables fast roaming; WPA-PSK is fallback for older clients.
wpa=2
wpa_passphrase=$password
# WPA-PSK only by default. FT-PSK (802.11r) enables fast roaming but some
# Samsung phones reject it. Uncomment the line below to enable 802.11r:
# wpa_key_mgmt=FT-PSK WPA-PSK
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
rsn_pairwise=CCMP

# 802.11r Fast Transition (seamless roaming between mesh nodes)
# Uncomment these if wpa_key_mgmt includes FT-PSK above:
# mobility_domain=4e57
# nas_identifier=nightwatch
# ft_over_ds=0
# ft_psk_generate_local=1
# pmk_r1_push=0

# 802.11n capabilities
wmm_enabled=1

ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
HAPEOF
}

# set_env_value <file> <key> <value>
# Safely sets key=value in an env file without sed escaping issues.
# Handles arbitrary characters in value (quotes, slashes, ampersands, backslashes).
set_env_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp="${file}.tmp.$$"

    # Secure temp file (may contain secrets like passwords)
    (umask 077 && : > "$tmp")

    # Strip surrounding quotes if the value is already quoted
    # (e.g. .secrets files may have KEY='value' to protect $)
    if [[ "$value" =~ ^\'(.*)\'$ ]]; then
        value="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
    fi

    # Wrap in single quotes if value contains shell-sensitive characters.
    # Single quotes in the value must be escaped as '\'' (end quote, escaped
    # literal quote, reopen quote) — the standard POSIX idiom.
    local quoted_value="$value"
    if [[ "$value" == *'$'* ]] || [[ "$value" == *'`'* ]] || [[ "$value" == *'\'* ]] || [[ "$value" == *'"'* ]] || [[ "$value" == *'!'* ]] || [[ "$value" == *"'"* ]]; then
        # Escape any single quotes inside the value: ' → '\''
        local escaped="${value//\'/\'\\\'\'}"
        quoted_value="'$escaped'"
    fi

    if grep -q "^${key}=" "$file" 2>/dev/null; then
        # Replace existing line in-place (preserves key ordering)
        # Use ENVIRON instead of -v to avoid awk interpreting backslash escapes
        if __SET_ENV_KEY="$key" __SET_ENV_VAL="$quoted_value" awk \
            'index($0, ENVIRON["__SET_ENV_KEY"]"=") == 1 {print ENVIRON["__SET_ENV_KEY"]"="ENVIRON["__SET_ENV_VAL"]; next} {print}' \
            "$file" > "$tmp"; then
            mv "$tmp" "$file"
        else
            rm -f "$tmp"
            return 1
        fi
    else
        # Append new key
        printf '%s=%s\n' "$key" "$quoted_value" >> "$file"
    fi

    # Flush to disk so a power loss doesn't leave a truncated/empty config
    sync 2>/dev/null || true
}

# check_deps <cmd1> [cmd2] ... — verifies required commands exist, exits with message if missing
check_deps() {
    local missing=""
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done
    if [ -n "$missing" ]; then
        echo "[-] Missing required commands:$missing" >&2
        echo "[-] Install with: sudo apt-get install -y$missing" >&2
        return 1
    fi
}

# configure_network — sets up dhcpcd/NetworkManager DNS and locks /etc/resolv.conf
# Shared between setup-rpi.sh and firstboot.sh to avoid duplication.
configure_network() {
    local DHCPCD_CONF="/etc/dhcpcd.conf"
    if [ -f "$DHCPCD_CONF" ]; then
        # Remove old broken Nightwatch config if present
        if grep -q "# Nightwatch network config" "$DHCPCD_CONF"; then
            sed -i '/# Nightwatch network config/,/^$/d' "$DHCPCD_CONF"
            sed -i '/# eth0 is the GL.iNet/d; /# wlan0 has internet/d; /# Fallback DNS when Tailscale/d' "$DHCPCD_CONF"
            echo "[+] Removed old Nightwatch dhcpcd config"
        fi
        # Static DNS
        if ! grep -q "# Nightwatch DNS" "$DHCPCD_CONF"; then
            cat >> "$DHCPCD_CONF" << 'NETEOF'

# Nightwatch DNS — hardcode DNS so we don't depend on DHCP-provided nameservers
static domain_name_servers=8.8.8.8 1.1.1.1
NETEOF
            echo "[+] dhcpcd configured: static DNS 8.8.8.8 + 1.1.1.1"
        fi
        # Deny bridge port interfaces
        if ! grep -q "denyinterfaces.*bat0" "$DHCPCD_CONF"; then
            cat >> "$DHCPCD_CONF" << 'DENYEOF'

# Nightwatch bridge — dhcpcd must not manage these (br0 bridge handles them)
denyinterfaces wlan2 bat0 br0
DENYEOF
            echo "[+] dhcpcd: wlan2/bat0/br0 excluded (bridge ports)"
        fi
        systemctl restart dhcpcd 2>/dev/null || true
    elif command -v nmcli >/dev/null 2>&1; then
        # wlan2 is a bridge port (br0 = bat0 + wlan2 via hostapd). NetworkManager
        # must NOT manage wlan2, otherwise it interferes with hostapd.
        # Use a persistent unmanaged rule so NM ignores wlan2 across reboots.
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/nightwatch-unmanaged.conf << 'NMEOF'
# Nightwatch: wlan2 and bat0 are bridge ports managed by mesh-fix.sh/hostapd
[keyfile]
unmanaged-devices=interface-name:wlan2;interface-name:bat0;interface-name:br0
NMEOF
        echo "[+] NetworkManager: wlan2/bat0/br0 set as permanently unmanaged"

        # Deactivate any existing NM connection on wlan2
        local WLAN2_CON
        WLAN2_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep 'wlan2' | head -1 | cut -d: -f1)
        if [ -n "$WLAN2_CON" ]; then
            nmcli con down "$WLAN2_CON" 2>/dev/null || true
            nmcli con mod "$WLAN2_CON" connection.autoconnect no 2>/dev/null || true
            echo "[+] Disabled auto-connect for NM connection '$WLAN2_CON'"
        fi
        nmcli dev set wlan2 managed no 2>/dev/null || true

        # Reload NM config so unmanaged rule takes effect
        systemctl reload NetworkManager 2>/dev/null || nmcli general reload 2>/dev/null || true

        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/nightwatch-fallback.conf << 'DNSEOF'
[Resolve]
FallbackDNS=8.8.8.8 1.1.1.1
DNSEOF
        systemctl restart systemd-resolved 2>/dev/null || true
        echo "[+] Fallback DNS configured (8.8.8.8, 1.1.1.1)"
    else
        echo "[!] Neither dhcpcd nor NetworkManager found — skipping network config"
    fi

    # Tell Tailscale to stop overwriting /etc/resolv.conf
    if command -v tailscale >/dev/null 2>&1; then
        tailscale set --accept-dns=false 2>/dev/null || true
    fi

    # Lock /etc/resolv.conf (prevents Tailscale, dhcpcd, etc. from overwriting)
    chattr -i /etc/resolv.conf 2>/dev/null || true
    cat > /etc/resolv.conf << 'DNSEOF'
nameserver 8.8.8.8
nameserver 1.1.1.1
DNSEOF
    if chattr +i /etc/resolv.conf 2>/dev/null; then
        echo "[+] /etc/resolv.conf locked (immutable) with 8.8.8.8 + 1.1.1.1"
    else
        echo "[!] Warning: could not lock /etc/resolv.conf (filesystem may not support chattr)"
    fi
}

# setup_persistent_wifi_names
# Creates udev rules to assign stable wlan1/wlan2 names based on USB port path.
# Without this, modprobe -r/modprobe ath9k_htc can swap interface names.
# Run once during install — rules persist across reboots and driver reloads.
setup_persistent_wifi_names() {
    local RULES_FILE="/etc/udev/rules.d/72-nightwatch-wifi.rules"
    local count=0

    # Find AR9271 dongles and their USB port paths
    for sysdev in /sys/bus/usb/devices/*/idVendor; do
        local usbdev
        usbdev=$(dirname "$sysdev")
        if [ "$(cat "$usbdev/idVendor" 2>/dev/null)" = "0cf3" ] && \
           [ "$(cat "$usbdev/idProduct" 2>/dev/null)" = "9271" ]; then
            local devpath
            devpath=$(basename "$usbdev")
            count=$((count + 1))
            if [ "$count" -eq 1 ]; then
                local path1="$devpath"
            elif [ "$count" -eq 2 ]; then
                local path2="$devpath"
            fi
        fi
    done

    if [ "$count" -lt 2 ]; then
        echo "[!] Found $count AR9271 dongle(s) — need 2 for persistent naming (mesh + AP)"
        return 0
    fi

    # Sort paths so the lower USB port is always wlan1 (mesh)
    if [ "$path1" \> "$path2" ]; then
        local tmp="$path1"; path1="$path2"; path2="$tmp"
    fi

    cat > "$RULES_FILE" << UDEVEOF
# Nightwatch: persistent WiFi dongle names by USB port
# wlan1 = mesh (802.11s), wlan2 = AP (hostapd)
# Generated by setup_persistent_wifi_names — do not edit
SUBSYSTEM=="net", ACTION=="add", DEVPATH=="*/$path1/*", DRIVERS=="ath9k_htc", NAME="wlan1"
SUBSYSTEM=="net", ACTION=="add", DEVPATH=="*/$path2/*", DRIVERS=="ath9k_htc", NAME="wlan2"
UDEVEOF

    echo "[+] Persistent WiFi naming: wlan1=$path1 (mesh), wlan2=$path2 (AP)"
    echo "[+] Rules written to $RULES_FILE"
    udevadm control --reload-rules 2>/dev/null || true
}

# install_systemd_services <project_dir>
# Installs all Nightwatch systemd service files from <project_dir>/scripts/
# into /etc/systemd/system/, replacing /opt/nightwatch with the actual path.
# Enables all services and reloads systemd.
install_systemd_services() {
    local project_dir="$1"

    chmod +x "$project_dir"/scripts/*.sh 2>/dev/null || true

    # Copy every nightwatch-*.{service,timer} from scripts/ into /etc/systemd/system/.
    # Globbing (vs. a hard-coded list) means new units added to scripts/ are
    # picked up automatically — avoids the class of bug where a `systemctl enable`
    # below references a unit that was never copied.
    # nightwatch-firstboot.service is excluded: it's installed by nightwatch-stage.sh
    # and is what's currently executing this code.
    shopt -s nullglob
    local src
    for src in "$project_dir"/scripts/nightwatch-*.service "$project_dir"/scripts/nightwatch-*.timer; do
        local name
        name=$(basename "$src")
        [ "$name" = "nightwatch-firstboot.service" ] && continue
        sed "s|/opt/nightwatch|$project_dir|g" "$src" > "/etc/systemd/system/$name"
    done
    shopt -u nullglob

    systemctl daemon-reload

    # Remove old DNS workaround if present
    systemctl disable nightwatch-dns.service 2>/dev/null || true
    rm -f /etc/systemd/system/nightwatch-dns.service

    systemctl enable nightwatch-nodeconfig.service
    systemctl enable nightwatch-mesh.service
    systemctl enable nightwatch-discovery.service
    systemctl enable nightwatch-app.service
    # Remove legacy nightwatch-docker.service if present (renamed to nightwatch-app)
    if systemctl is-enabled nightwatch-docker.service >/dev/null 2>&1; then
        systemctl disable nightwatch-docker.service 2>/dev/null || true
        rm -f /etc/systemd/system/nightwatch-docker.service
    fi
    systemctl enable nightwatch-bridge.service
    systemctl enable nightwatch-led.service
    systemctl enable nightwatch-debug.service
    systemctl enable nightwatch-watchdog.timer
    systemctl enable nightwatch-arp-refresh.service
    # nightwatch-roamer.service is intentionally NOT enabled here.
    # The 802.11v steering daemon is experimental — opt in per node with:
    #   sudo systemctl enable --now nightwatch-roamer.service
    # See the header comment in scripts/nightwatch-roamer.service for details.

    echo "[+] Systemd services installed and enabled"
}
