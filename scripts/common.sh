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

# Maximum number of nodes in the mesh (IPs .101-.120)
MAX_NODES=20

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
PingTimeout = 300
PongTimeout = 60
IdleTimeout = 900
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
# Writes the dnsmasq.conf template for captive portal + DHCP.
generate_dnsmasq_conf() {
    local conf_path="$1"
    local node_num="$2"
    local mesh_ip="${3%/*}"  # strip CIDR suffix if present

    # Validate node_num is within range (prevents invalid DHCP ranges)
    if ! [[ "$node_num" =~ ^[0-9]+$ ]] || [ "$node_num" -lt 1 ] || [ "$node_num" -gt "$MAX_NODES" ]; then
        echo "generate_dnsmasq_conf: node_num $node_num out of range (1-$MAX_NODES)" >&2
        return 1
    fi

    local dhcp_start=$((200 + (node_num - 1) * 5 + 1))
    local dhcp_end=$((200 + (node_num - 1) * 5 + 5))
    # Cap at .254 to stay within /24 subnet
    [ "$dhcp_end" -gt 254 ] && dhcp_end=254
    if [ "$dhcp_start" -gt 254 ]; then
        echo "generate_dnsmasq_conf: node $node_num has no DHCP range (start .${dhcp_start} > .254)" >&2
        echo "  Reduce MAX_NODES or use fewer nodes. Max 11 nodes fit in .201-.254." >&2
        return 1
    fi

    mkdir -p "$(dirname "$conf_path")"

    cat > "$conf_path" << DNSEOF
# Nightwatch dnsmasq — DHCP + captive portal DNS for WiFi clients
# Auto-generated — do not edit manually

# Only listen on the mesh bridge
interface=br0
bind-interfaces

# DHCP range for WiFi clients (each node gets 5 addresses to avoid conflicts)
# Batman-adv bridges all routers, so DHCP broadcasts reach every node's dnsmasq.
# Non-overlapping ranges prevent duplicate leases: 20 nodes × 5 = .201-.240+
dhcp-range=192.168.199.${dhcp_start},192.168.199.${dhcp_end},255.255.255.0,1h

# Tell clients to use this node as gateway and DNS
dhcp-option=3,${mesh_ip}
dhcp-option=6,${mesh_ip}

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

# resolve_node_mode — sets NODE_MODE from env, with backward compat for MESH_GATEWAY
# Valid modes: mesh (default), gateway, sound-bridge
# If NODE_MODE is not set but MESH_GATEWAY=true, maps to gateway mode.
resolve_node_mode() {
    local mode="${NODE_MODE:-}"

    # Backward compat: MESH_GATEWAY=true → gateway mode
    if [ -z "$mode" ] && [ "${MESH_GATEWAY:-false}" = "true" ]; then
        mode="gateway"
    fi

    # Default to mesh
    mode="${mode:-mesh}"

    # Validate
    case "$mode" in
        mesh|gateway|sound-bridge) ;;
        *)
            echo "resolve_node_mode: unknown mode '$mode' (valid: mesh, gateway, sound-bridge)" >&2
            mode="mesh"
            ;;
    esac

    NODE_MODE="$mode"
    export NODE_MODE
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
        if ! grep -q "denyinterfaces eth0" "$DHCPCD_CONF"; then
            cat >> "$DHCPCD_CONF" << 'DENYEOF'

# Nightwatch bridge — dhcpcd must not manage these (br0 bridge handles them)
denyinterfaces eth0 bat0 br0
DENYEOF
            echo "[+] dhcpcd: eth0/bat0/br0 excluded (bridge ports)"
        fi
        systemctl restart dhcpcd 2>/dev/null || true
    elif command -v nmcli >/dev/null 2>&1; then
        # eth0 is a bridge port (br0 = bat0 + eth0). NetworkManager must NOT
        # manage eth0, otherwise it runs DHCP, fails, and detaches eth0 from
        # br0 — breaking the captive portal. Use a persistent udev-style
        # unmanaged rule so NM ignores eth0 across reboots.
        mkdir -p /etc/NetworkManager/conf.d
        cat > /etc/NetworkManager/conf.d/nightwatch-unmanaged.conf << 'NMEOF'
# Nightwatch: eth0 and bat0 are bridge ports managed by mesh-fix.sh
[keyfile]
unmanaged-devices=interface-name:eth0;interface-name:bat0;interface-name:br0
NMEOF
        echo "[+] NetworkManager: eth0/bat0/br0 set as permanently unmanaged"

        # Deactivate any existing NM connection on eth0
        local ETH_CON
        ETH_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep 'eth0' | head -1 | cut -d: -f1)
        if [ -n "$ETH_CON" ]; then
            nmcli con down "$ETH_CON" 2>/dev/null || true
            # Prevent auto-activation
            nmcli con mod "$ETH_CON" connection.autoconnect no 2>/dev/null || true
            echo "[+] Disabled auto-connect for NM connection '$ETH_CON'"
        fi
        nmcli dev set eth0 managed no 2>/dev/null || true

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

# install_systemd_services <project_dir>
# Installs all Nightwatch systemd service files from <project_dir>/scripts/
# into /etc/systemd/system/, replacing /opt/nightwatch with the actual path.
# Enables all services and reloads systemd.
install_systemd_services() {
    local project_dir="$1"

    chmod +x "$project_dir"/scripts/*.sh 2>/dev/null || true

    for svc in nightwatch-nodeconfig nightwatch-mesh nightwatch-discovery nightwatch-app nightwatch-bridge nightwatch-led nightwatch-debug; do
        local src="$project_dir/scripts/${svc}.service"
        if [ -f "$src" ]; then
            sed "s|/opt/nightwatch|$project_dir|g" "$src" > "/etc/systemd/system/${svc}.service"
        fi
    done

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

    echo "[+] Systemd services installed and enabled"
}
