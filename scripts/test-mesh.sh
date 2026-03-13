#!/bin/bash
# Nightwatch — Mesh network integration test
# Run from any node in the mesh to verify full connectivity
#
# Tests:
#   1. Local mesh health (batman-adv, 802.11s, interfaces)
#   2. Node discovery (ping all configured nodes, find who's online)
#   3. batman-adv topology (neighbors, originators)
#   4. App services (local + remote live nodes)
#   5. IRC cross-node messaging (if >1 node online)
#   6. Access point status
#   7. Gateway / internet connectivity
#   8. Local service health
#
# Usage: sudo ./scripts/test-mesh.sh [--quick]
#   --quick  Skip slow tests (cross-node IRC, latency matrix)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASSED=0
FAILED=0
SKIPPED=0
WARNINGS=0

pass()    { ((PASSED++))  || true; echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail()    { ((FAILED++))  || true; echo -e "  ${RED}[FAIL]${NC} $1"; }
skip()    { ((SKIPPED++)) || true; echo -e "  ${YELLOW}[SKIP]${NC} $1"; }
warn()    { ((WARNINGS++))|| true; echo -e "  ${YELLOW}[WARN]${NC} $1"; }
section() { echo ""; echo -e "${BOLD}${CYAN}== $1 ==${NC}"; }

QUICK_MODE=false
if [ "${1:-}" = "--quick" ]; then
    QUICK_MODE=true
fi

# Cleanup trap — kill background processes and remove temp files on exit
cleanup() {
    local pids
    pids=$(jobs -p 2>/dev/null) || true
    if [ -n "$pids" ]; then
        kill $pids 2>/dev/null || true
    fi
    rm -f /tmp/nightwatch-test-*.$$
}
trap cleanup EXIT

# ---- Load config ----

load_env "$ENV_FILE"

BAT_IFACE="${BAT_IFACE:-bat0}"
BR_IFACE="${BR_IFACE:-br0}"
MESH_IFACE="${MESH_IFACE:-wlan1}"
AP_IFACE="${AP_IFACE:-eth0}"
IRC_PORT="${IRC_PORT:-6667}"
NGINX_PORT="${NGINX_PORT:-80}"
LOCAL_IP="${MESH_IP%/*}"

# Node list: all possible mesh IPs (192.168.199.101-120, max 20 nodes)
declare -a NODE_IPS=()
declare -a NODE_NAMES=()
for i in $(seq 1 "$MAX_NODES"); do
    NODE_IPS+=("$(mesh_ip_for_node "$i")")
    NODE_NAMES+=("node${i}")
done

echo "======================================"
echo "  Nightwatch Mesh Integration Test"
echo "======================================"
echo ""
resolve_node_mode
echo "  This node:  $LOCAL_IP (node #${PI_NUMBER:-?})"
echo "  Node mode:  $NODE_MODE"
echo "  Scanning:   192.168.199.101-$((100 + MAX_NODES)) (max $MAX_NODES nodes)"
echo "  Test mode:  $([ "$QUICK_MODE" = true ] && echo 'quick' || echo 'full')"
echo ""

# ---- Check we're running as root ----

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}Warning: some tests require root. Run with sudo for full coverage.${NC}"
    echo ""
fi

# ============================================================
# 0. Hardware & System
# ============================================================

section "0. Hardware & System"

# USB WiFi dongle (AR9271) detected
if lsusb 2>/dev/null | grep -q "0cf3:9271"; then
    pass "USB WiFi dongle (AR9271) detected"
elif ip link show "$MESH_IFACE" >/dev/null 2>&1; then
    pass "Mesh interface $MESH_IFACE present (dongle detected)"
else
    fail "USB WiFi dongle (AR9271) not detected"
fi

# Disk space — warn if root partition is >90% full
DISK_USAGE=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "0")
if [ "$DISK_USAGE" -lt 90 ]; then
    pass "Disk usage: ${DISK_USAGE}%"
elif [ "$DISK_USAGE" -lt 95 ]; then
    warn "Disk usage high: ${DISK_USAGE}%"
else
    fail "Disk nearly full: ${DISK_USAGE}%"
fi

# Internet connectivity (via wlan0 or default route, not mesh)
if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
    pass "Internet reachable (ping 8.8.8.8)"
else
    warn "No internet (8.8.8.8 unreachable — Tailscale/apt/git won't work)"
fi

# Ethernet link state
ETH_STATE=$(cat /sys/class/net/"$AP_IFACE"/operstate 2>/dev/null || echo "unknown")
if [ "$ETH_STATE" = "up" ]; then
    pass "$AP_IFACE link: up"
else
    warn "$AP_IFACE link: $ETH_STATE (router may be off)"
fi

# ============================================================
# 1. Local Mesh Health
# ============================================================

section "1. Local Mesh Health"

# batman-adv loaded (module or built-in)
if lsmod | grep -q batman_adv || [ -d /sys/module/batman_adv ]; then
    version=$(cat /sys/module/batman_adv/version 2>/dev/null || echo "unknown")
    pass "batman-adv available (v$version)"
else
    fail "batman-adv not loaded"
fi

# bat0 interface exists and has IP
if [ -d "/sys/class/net/$BAT_IFACE" ]; then
    pass "$BAT_IFACE interface exists"
else
    fail "$BAT_IFACE interface not found"
fi

# Mesh IP lives on br0 (Linux bridge over bat0 + eth0)
mesh_ip_iface="$BR_IFACE"
if [ ! -d "/sys/class/net/$BR_IFACE" ]; then
    # Fallback: maybe IP is still on bat0 (no bridge yet)
    mesh_ip_iface="$BAT_IFACE"
fi
mesh_ip_actual=$(ip -4 addr show dev "$mesh_ip_iface" 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "")
if [ -n "$mesh_ip_actual" ]; then
    pass "$mesh_ip_iface has IP: $mesh_ip_actual"
    if [ "$mesh_ip_actual" = "$LOCAL_IP" ]; then
        pass "$mesh_ip_iface IP matches MESH_IP ($LOCAL_IP)"
    else
        fail "$mesh_ip_iface IP ($mesh_ip_actual) does not match MESH_IP ($LOCAL_IP)"
    fi
else
    fail "No mesh IP found on $BR_IFACE or $BAT_IFACE"
fi

# Mesh interface in 802.11s mode
mesh_type=$(iw dev "$MESH_IFACE" info 2>/dev/null | grep type | awk '{print $2}' || echo "")
if [ "$mesh_type" = "mesh" ]; then
    pass "$MESH_IFACE is in mesh point mode"
else
    fail "$MESH_IFACE type is '$mesh_type' (expected 'mesh')"
fi

# Mesh interface added to batman
bat_ifaces=$(batctl meshif "$BAT_IFACE" if 2>/dev/null || batctl if 2>/dev/null || echo "")
if echo "$bat_ifaces" | grep -q "$MESH_IFACE"; then
    pass "$MESH_IFACE is registered in batman-adv"
else
    fail "$MESH_IFACE not found in batman-adv interfaces"
fi

# batman-adv gateway mode
gw_mode=$(batctl meshif "$BAT_IFACE" gw_mode 2>/dev/null || batctl gw_mode 2>/dev/null || echo "unknown")
if [ "$NODE_MODE" = "gateway" ]; then
    if echo "$gw_mode" | grep -qi "server"; then
        pass "Gateway mode: server (as configured)"
    else
        fail "Gateway mode should be 'server' but got: $gw_mode"
    fi
else
    if echo "$gw_mode" | grep -qi "client\|off"; then
        pass "Gateway mode: client (as configured — mode: $NODE_MODE)"
    else
        warn "Gateway mode unexpected: $gw_mode"
    fi
fi

# ============================================================
# 2. Node Discovery
# ============================================================

section "2. Node Discovery"

# Check for node/IP conflicts
CONFLICT_FILE="/run/nightwatch-conflict"
if [ -f "$CONFLICT_FILE" ]; then
    fail "NODE CONFLICT: $(cat "$CONFLICT_FILE")"
else
    pass "No node conflicts detected"
fi

# Check if discovery daemon is running
if systemctl is-active nightwatch-discovery.service >/dev/null 2>&1; then
    pass "Discovery daemon running"
    PEER_FILE="/run/nightwatch-peers"
    if [ -f "$PEER_FILE" ] && [ -s "$PEER_FILE" ]; then
        peer_count=$(wc -l < "$PEER_FILE")
        pass "Discovery daemon knows $peer_count peer(s)"
    else
        skip "Discovery daemon has no peers yet"
    fi
else
    warn "Discovery daemon not running"
fi

declare -a LIVE_IPS=()
declare -a LIVE_NAMES=()

# Scan via mesh interface only (br0/bat0) — not via LAN/Tailscale
SCAN_IFACE="$BR_IFACE"
if [ ! -d "/sys/class/net/$BR_IFACE" ]; then
    SCAN_IFACE="$BAT_IFACE"
fi
echo "  Scanning 192.168.199.101-120 via $SCAN_IFACE..."
if command -v fping >/dev/null 2>&1; then
    # Fast parallel scan with fping bound to mesh interface
    ALL_IPS=$(for i in $(seq 1 "$MAX_NODES"); do mesh_ip_for_node "$i"; done)
    FPING_OUT=$(echo "$ALL_IPS" | fping -a -e -r 1 -t 500 -I "$SCAN_IFACE" 2>/dev/null || true)
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ip=$(echo "$line" | awk '{print $1}')
        rtt=$(echo "$line" | grep -oP '\(.*\)' || echo "(?)")
        [ "$ip" = "$LOCAL_IP" ] && continue
        i=$((${ip##*.} - 100))
        name="node${i}"
        echo -e "  ${GREEN}[ONLINE]${NC}  $ip ($name) — ${rtt}"
        LIVE_IPS+=("$ip")
        LIVE_NAMES+=("$name")
    done <<< "$FPING_OUT"
else
    # Fallback: sequential ping bound to mesh interface
    for idx in "${!NODE_IPS[@]}"; do
        ip="${NODE_IPS[$idx]}"
        name="${NODE_NAMES[$idx]}"
        [ "$ip" = "$LOCAL_IP" ] && continue
        if ping -c 1 -W 1 -I "$SCAN_IFACE" "$ip" >/dev/null 2>&1; then
            rtt=$(ping -c 1 -W 1 -I "$SCAN_IFACE" "$ip" 2>/dev/null | grep 'time=' | sed 's/.*time=//' || echo "?")
            echo -e "  ${GREEN}[ONLINE]${NC}  $ip ($name) — ${rtt}"
            LIVE_IPS+=("$ip")
            LIVE_NAMES+=("$name")
        fi
    done
fi

live_count=${#LIVE_IPS[@]}
echo ""
if [ "$live_count" -gt 0 ]; then
    echo "  Discovered: $live_count remote node(s)"
    pass "$live_count remote node(s) reachable"
else
    echo "  No other nodes found on the mesh"
    skip "This node is alone"
fi

# ============================================================
# 3. 802.11s Mesh Peers
# ============================================================

section "3. 802.11s Mesh Peers"

station_dump=$(iw dev "$MESH_IFACE" station dump 2>/dev/null || true)
peer_count=$(echo "$station_dump" | grep -c "^Station" || true)
peer_count=$((peer_count + 0))

if [ "$peer_count" -gt 0 ]; then
    pass "802.11s has $peer_count mesh peer(s)"
    # Check peer link states
    established=$(echo "$station_dump" | grep "mesh plink:" | grep -c "ESTAB" || true)
    established=$((established + 0))
    if [ "$established" -gt 0 ]; then
        pass "$established peer link(s) ESTABLISHED"
    else
        warn "No established peer links"
    fi
elif [ ${#LIVE_IPS[@]} -gt 0 ]; then
    warn "No direct 802.11s peers (nodes may be multi-hop via batman-adv)"
else
    skip "No 802.11s peers (no other nodes online)"
fi

# ============================================================
# 4. batman-adv Topology
# ============================================================

section "4. batman-adv Topology"

# Neighbors — only count mesh interface (MESH_IFACE) neighbors, not bridged AP clients
neighbor_output=$(batctl meshif "$BAT_IFACE" n 2>/dev/null || batctl n 2>/dev/null || true)
mesh_neighbor_count=$(echo "$neighbor_output" | grep -c "$MESH_IFACE" || true)
mesh_neighbor_count=$((mesh_neighbor_count + 0))
total_neighbor_count=$(echo "$neighbor_output" | grep -cv "^\[B.A.T.M.A.N\|^$\|IF" || true)
total_neighbor_count=$((total_neighbor_count + 0))
if [ "$mesh_neighbor_count" -gt 0 ]; then
    extra=""
    bridged=$((total_neighbor_count - mesh_neighbor_count))
    if [ "$bridged" -gt 0 ]; then
        extra=" (+$bridged bridged client(s))"
    fi
    pass "batman-adv has $mesh_neighbor_count mesh neighbor(s)${extra}"
else
    skip "No batman-adv mesh neighbors (no mesh peers)"
fi

# Originators — count only best routes (* prefix = unique originator)
originator_output=$(batctl meshif "$BAT_IFACE" o 2>/dev/null || batctl o 2>/dev/null || true)
originator_count=$(echo "$originator_output" | grep -c "^ \*" || true)
originator_count=$((originator_count + 0))
if [ "$originator_count" -gt 0 ]; then
    pass "batman-adv sees $originator_count originator(s) in mesh"
else
    skip "No batman-adv originators (no mesh peers)"
fi

# Gateway list — only count lines with actual MAC addresses
gw_list=$(batctl meshif "$BAT_IFACE" gwl 2>/dev/null || batctl gwl 2>/dev/null || true)
gw_count=$(echo "$gw_list" | grep -cE "([0-9a-f]{2}:){5}[0-9a-f]{2}" || true)
gw_count=$((gw_count + 0))
if [ "$gw_count" -gt 0 ]; then
    pass "batman-adv sees $gw_count gateway(s)"
elif [ "${MESH_GATEWAY:-false}" = "true" ]; then
    warn "This node is a gateway but no gateways in list (may need time)"
else
    skip "No gateways in mesh"
fi

# ============================================================
# 5. Latency Matrix (full mode, only live nodes)
# ============================================================

if [ "$QUICK_MODE" = false ] && [ ${#LIVE_IPS[@]} -gt 0 ]; then
    section "5. Latency Matrix"

    echo "  From this node ($LOCAL_IP):"
    for idx in "${!LIVE_IPS[@]}"; do
        ip="${LIVE_IPS[$idx]}"
        name="${LIVE_NAMES[$idx]}"

        # Ping via br0 (bridge over bat0 + eth0) — bat0 no longer has an IP
        ping_iface="$BR_IFACE"
        if [ ! -d "/sys/class/net/$BR_IFACE" ]; then
            ping_iface="$BAT_IFACE"
        fi
        ping_output=$(ping -c 5 -W 2 -I "$ping_iface" "$ip" 2>/dev/null || true)
        result=$(echo "$ping_output" | tail -1)
        if echo "$result" | grep -q "/"; then
            min=$(echo "$result" | awk -F'/' '{print $4}')
            avg=$(echo "$result" | awk -F'/' '{print $5}')
            max=$(echo "$result" | awk -F'/' '{print $6}')
            loss=$(echo "$ping_output" | grep "packet loss" | awk -F',' '{print $3}' | tr -d ' ')
            echo -e "    → $ip ($name): min=${min}ms avg=${avg}ms max=${max}ms $loss"
            # Flag high latency
            avg_int=${avg%.*}
            if [ "${avg_int:-0}" -gt 100 ]; then
                warn "$ip latency high (${avg}ms avg)"
            fi
        else
            echo -e "    → $ip ($name): ${RED}unreachable over $ping_iface${NC}"
        fi
    done
else
    section "5. Latency Matrix"
    if [ ${#LIVE_IPS[@]} -eq 0 ]; then
        skip "No other nodes online"
    else
        skip "Skipped in quick mode"
    fi
fi

# ============================================================
# 6. App Services (local + live remote nodes)
# ============================================================

section "6. App Services"

# Wait for services to be ready before testing ports (prevents false fails
# when tests run right after startup)
for _wait_attempt in 1 2 3 4 5 6; do
    _all_ready=true
    for _svc in ngircd nightwatch-bridge nginx; do
        if ! systemctl is-active --quiet "$_svc" 2>/dev/null; then
            _all_ready=false
            break
        fi
    done
    $_all_ready && break
    [ "$_wait_attempt" -lt 6 ] && sleep 10
done

# Local services
echo -e "  ${BOLD}$LOCAL_IP (this node) — local:${NC}"

if nc -z localhost "$IRC_PORT" 2>/dev/null; then
    pass "  IRC (port $IRC_PORT) listening"
else
    fail "  IRC (port $IRC_PORT) not reachable"
fi

health=$(curl -sf --max-time 3 http://localhost:3000/health 2>/dev/null || echo "")
if [ "$health" = "OK" ]; then
    pass "  Bridge /health returns OK"
else
    fail "  Bridge /health returned: '$health'"
fi

if curl -sf --max-time 3 "http://localhost:${NGINX_PORT}/" >/dev/null 2>&1; then
    pass "  Nginx (port $NGINX_PORT) serves frontend"
else
    fail "  Nginx (port $NGINX_PORT) not reachable"
fi

# Remote live nodes only
for idx in "${!LIVE_IPS[@]}"; do
    ip="${LIVE_IPS[$idx]}"
    name="${LIVE_NAMES[$idx]}"
    echo -e "  ${BOLD}$ip ($name) — remote:${NC}"

    if nc -z -w 3 "$ip" "$IRC_PORT" 2>/dev/null; then
        pass "  IRC (port $IRC_PORT) reachable"
    else
        fail "  IRC (port $IRC_PORT) not reachable"
    fi

    # Bridge port isn't exposed — check via nginx /ws proxy (400 = bridge is alive)
    ws_code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://${ip}:${NGINX_PORT}/ws" 2>/dev/null || echo "000")
    if [ "$ws_code" = "400" ] || [ "$ws_code" = "426" ] || [ "$ws_code" = "101" ]; then
        pass "  Bridge reachable via nginx /ws (HTTP $ws_code)"
    else
        fail "  Bridge not reachable via nginx /ws (HTTP $ws_code)"
    fi

    nginx_code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "http://${ip}:${NGINX_PORT}/" 2>/dev/null || echo "000")
    if [ "$nginx_code" = "200" ]; then
        pass "  Nginx (port $NGINX_PORT) returns HTTP 200"
    elif [ "$nginx_code" != "000" ]; then
        warn "  Nginx (port $NGINX_PORT) returns HTTP $nginx_code"
    else
        fail "  Nginx (port $NGINX_PORT) not reachable"
    fi
done

# ============================================================
# 7. IRC Cross-Node Messaging (only if live remote nodes)
# ============================================================

if [ "$QUICK_MODE" = false ] && [ ${#LIVE_IPS[@]} -gt 0 ]; then
    section "7. IRC Cross-Node Messaging"

    # Pick the first remote node with IRC reachable
    REMOTE_IP=""
    REMOTE_NAME=""
    for idx in "${!LIVE_IPS[@]}"; do
        ip="${LIVE_IPS[$idx]}"
        if nc -z -w 2 "$ip" "$IRC_PORT" 2>/dev/null; then
            REMOTE_IP="$ip"
            REMOTE_NAME="${LIVE_NAMES[$idx]}"
            break
        fi
    done

    if [ -z "$REMOTE_IP" ]; then
        skip "No remote IRC server reachable"
    else
        # Pre-check: verify IRC servers are actually federated before messaging test
        FED_OK=true
        irc_logs=$(journalctl -u ngircd --no-pager --since "5 minutes ago" 2>&1 || true)

        # Check for bad password errors (federation broken)
        if echo "$irc_logs" | grep -q "Bad password"; then
            fail "IRC federation broken: server link password mismatch (check IRC_LINK_PASSWORD in .env on all nodes)"
            FED_OK=false
        fi

        # Check if any server link is established by querying ngircd via IRC LINKS command
        LINKS_OUTPUT=$(mktemp)
        {
            echo "NICK fc$$"
            echo "USER fc$$ 0 * :Federation Check"
            sleep 2
            echo "LINKS"
            sleep 2
            echo "QUIT :check done"
        } | nc -w 8 localhost "$IRC_PORT" > "$LINKS_OUTPUT" 2>&1 || true

        # Count linked servers (LINKS replies are RPL_LINKS 364, end is RPL_ENDOFLINKS 365)
        linked_servers=$(grep -c " 364 " "$LINKS_OUTPUT" 2>/dev/null || true)
        linked_servers=$((linked_servers + 0))

        if [ "$linked_servers" -le 1 ]; then
            # Only see ourselves (or nothing) — no remote servers linked
            if [ "$FED_OK" = true ]; then
                fail "IRC servers not linked (no federation peers connected)"
            fi
            FED_OK=false
        else
            pass "IRC federation active ($linked_servers server(s) linked)"
        fi
        rm -f "$LINKS_OUTPUT"

        if [ "$FED_OK" = false ]; then
            skip "Cross-node messaging (federation not established)"
        else
            echo "  Testing: send on $LOCAL_IP → verify on $REMOTE_IP ($REMOTE_NAME)"

            TEST_MSG="MESHTEST_$(date +%s)_$$"
            TEST_NICK="tb$$"

            # Start RECEIVER first on remote node — give it time to connect and join
            RECV_OUTPUT=$(mktemp)
            {
                echo "NICK rb$$"
                echo "USER rb$$ 0 * :Mesh Recv Bot"
                sleep 4
                echo "JOIN #nightwatch"
                sleep 15
                echo "QUIT :recv done"
            } | nc -w 22 "$REMOTE_IP" "$IRC_PORT" > "$RECV_OUTPUT" 2>&1 &
            RECV_PID=$!

            # Wait for receiver to fully connect, register, and join channel
            sleep 8

            # Then SEND on local node
            {
                echo "NICK $TEST_NICK"
                echo "USER $TEST_NICK 0 * :Mesh Test Bot"
                sleep 3
                echo "JOIN #nightwatch"
                sleep 2
                echo "PRIVMSG #nightwatch :$TEST_MSG"
                sleep 3
                echo "QUIT :test done"
            } | nc -w 12 localhost "$IRC_PORT" >/dev/null 2>&1 &
            SEND_PID=$!

            # Wait for both to finish
            wait $SEND_PID 2>/dev/null || true
            wait $RECV_PID 2>/dev/null || true

            # Check if remote received the message
            if grep -q "$TEST_MSG" "$RECV_OUTPUT" 2>/dev/null; then
                pass "Message delivered across mesh: $LOCAL_IP → $REMOTE_IP"
            else
                fail "Message not received on $REMOTE_IP (IRC federation may need time)"
            fi

            rm -f "$RECV_OUTPUT"
        fi
    fi
else
    section "7. IRC Cross-Node Messaging"
    if [ ${#LIVE_IPS[@]} -eq 0 ]; then
        skip "No other nodes online"
    else
        skip "Skipped in quick mode"
    fi
fi

# ============================================================
# 8. Access Point
# ============================================================

section "8. Client Bridge ($BR_IFACE)"

# Check if Linux bridge br0 exists and has the right ports
if [ -d "/sys/class/net/$BR_IFACE" ]; then
    pass "$BR_IFACE bridge exists"

    br_state=$(cat "/sys/class/net/$BR_IFACE/operstate" 2>/dev/null || echo "unknown")
    if [ "$br_state" = "up" ]; then
        pass "$BR_IFACE is up"
    else
        warn "$BR_IFACE state: $br_state"
    fi

    # Check bat0 is a bridge port
    if [ -d "/sys/class/net/$BR_IFACE/brif/$BAT_IFACE" ]; then
        pass "$BAT_IFACE is a port of $BR_IFACE"
    else
        fail "$BAT_IFACE not in $BR_IFACE (mesh traffic won't reach bridge)"
    fi

    # Check eth0 is a bridge port (not expected in sound-bridge mode)
    if [ "$NODE_MODE" = "sound-bridge" ]; then
        if [ -d "/sys/class/net/$BR_IFACE/brif/$AP_IFACE" ]; then
            warn "$AP_IFACE should NOT be in $BR_IFACE in sound-bridge mode"
        else
            pass "$AP_IFACE correctly excluded from $BR_IFACE (sound-bridge mode)"
        fi
        # Check eth0 has the Mac Mini subnet IP
        eth0_ip=$(ip -4 addr show dev "$AP_IFACE" 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "")
        if [ "$eth0_ip" = "10.0.0.1" ]; then
            pass "$AP_IFACE has 10.0.0.1 (Mac Mini subnet)"
        else
            fail "$AP_IFACE should have 10.0.0.1 but has '$eth0_ip'"
        fi
    else
        if [ -d "/sys/class/net/$BR_IFACE/brif/$AP_IFACE" ]; then
            pass "$AP_IFACE is a port of $BR_IFACE"
        else
            warn "$AP_IFACE not in $BR_IFACE (run: sudo ip link set $AP_IFACE master $BR_IFACE)"
        fi
    fi
else
    fail "$BR_IFACE bridge not found (eth0 and bat0 are not bridged)"
fi

# ============================================================
# 9. Gateway & Internet
# ============================================================

section "9. Gateway & Internet"

if [ "$NODE_MODE" = "gateway" ]; then
    echo "  This node is configured as gateway"

    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    if [ "$fwd" = "1" ]; then
        pass "IP forwarding enabled"
    else
        fail "IP forwarding disabled"
    fi

    if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE"; then
        pass "NAT/MASQUERADE rule active"
    else
        fail "No MASQUERADE rule (internet sharing broken)"
    fi

    if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
        pass "Internet reachable (8.8.8.8)"
    else
        fail "Internet not reachable from gateway"
    fi
elif [ "$NODE_MODE" = "sound-bridge" ]; then
    echo "  This node is configured as sound-bridge"

    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    if [ "$fwd" = "1" ]; then
        pass "IP forwarding enabled (mesh <-> Mac Mini)"
    else
        fail "IP forwarding disabled (sound-bridge needs it)"
    fi

    if ping -c 1 -W 2 10.0.0.2 >/dev/null 2>&1; then
        pass "Mac Mini reachable at 10.0.0.2"
    else
        warn "Mac Mini not reachable at 10.0.0.2 (may not be connected)"
    fi
else
    if [ "$gw_count" -gt 0 ]; then
        pass "Gateway available in mesh ($gw_count gateway(s))"
    else
        skip "No gateway in mesh (nodes use their own uplink)"
    fi
    if ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
        pass "Internet reachable"
    else
        warn "Internet not reachable"
    fi
fi

# ============================================================
# 10. Captive Portal & DNS
# ============================================================

section "10. Captive Portal & DNS"

# dnsmasq running
DNSMASQ_PID="/var/run/dnsmasq-nightwatch.pid"
if [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID" 2>/dev/null)" 2>/dev/null; then
    pass "dnsmasq running (PID $(cat "$DNSMASQ_PID"))"
else
    fail "dnsmasq not running"
fi

# Use iptables -S for exact rule matching (includes interface spec)
IPTABLES_NAT=$(iptables -t nat -S PREROUTING 2>/dev/null || true)

# iptables DNS redirect (port 53 on br0)
if echo "$IPTABLES_NAT" | grep -q "\-i $BR_IFACE.*--dport 53.*DNAT"; then
    pass "iptables DNS redirect active (port 53 on $BR_IFACE)"
else
    fail "iptables DNS redirect missing (port 53 on $BR_IFACE)"
fi

# iptables HTTP redirect (port 80 on br0)
if echo "$IPTABLES_NAT" | grep -q "\-i $BR_IFACE.*--dport 80.*DNAT"; then
    pass "iptables HTTP redirect active (port 80 on $BR_IFACE)"
else
    fail "iptables HTTP redirect missing (port 80 on $BR_IFACE)"
fi

# Port 443 must NOT have a DNAT rule — no HTTPS listener means browsers get
# "connection refused" and fall back to HTTP automatically.
if echo "$IPTABLES_NAT" | grep -q "\-i $BR_IFACE.*--dport 443.*DNAT"; then
    warn "iptables HTTPS DNAT still active (port 443) — should be removed for HTTP fallback"
else
    pass "No port 443 DNAT (browsers fall back to HTTP)"
fi

# DNS resolution — all domains should resolve to local IP
DNS_RESULT=$(dig +short @"$LOCAL_IP" google.com A 2>/dev/null || nslookup google.com "$LOCAL_IP" 2>/dev/null | grep -oP 'Address: \K[0-9.]+' | tail -1 || echo "")
if [ "$DNS_RESULT" = "$LOCAL_IP" ]; then
    pass "DNS captive portal: google.com resolves to $LOCAL_IP"
elif [ -n "$DNS_RESULT" ]; then
    fail "DNS captive portal: google.com resolves to $DNS_RESULT (expected $LOCAL_IP)"
else
    # Try with host command as fallback
    DNS_RESULT2=$(host google.com "$LOCAL_IP" 2>/dev/null | grep -oP 'address \K[0-9.]+' | head -1 || echo "")
    if [ "$DNS_RESULT2" = "$LOCAL_IP" ]; then
        pass "DNS captive portal: google.com resolves to $LOCAL_IP"
    else
        warn "DNS resolution test inconclusive (dig/nslookup/host not available or failed)"
    fi
fi

# DHCP leases — check dnsmasq is handing out leases
LEASE_FILE="/var/lib/misc/dnsmasq.leases"
if [ -f "$LEASE_FILE" ]; then
    LEASE_COUNT=$(wc -l < "$LEASE_FILE" 2>/dev/null || echo "0")
    pass "DHCP lease file exists ($LEASE_COUNT active lease(s))"
else
    skip "No DHCP leases yet (no clients have connected)"
fi

# ============================================================
# 11. Local Service Health
# ============================================================

section "11. Local Service Health"

for svc in ngircd nightwatch-bridge nginx; do
    state=$(systemctl is-active "$svc" 2>/dev/null || echo "not found")
    if [ "$state" = "active" ]; then
        pass "$svc: active"
    elif [ "$state" = "activating" ]; then
        warn "$svc: still starting"
    else
        fail "$svc: $state"
    fi
done

# ============================================================
# Summary
# ============================================================

echo ""
echo "======================================"
echo "  Mesh Integration Test Results"
echo "======================================"
echo -e "  ${GREEN}Passed:   $PASSED${NC}"
echo -e "  ${RED}Failed:   $FAILED${NC}"
echo -e "  ${YELLOW}Warnings: $WARNINGS${NC}"
echo -e "  ${YELLOW}Skipped:  $SKIPPED${NC}"
if [ ${#LIVE_IPS[@]} -gt 0 ]; then
    echo "  Live nodes: ${#LIVE_IPS[@]}"
else
    echo "  Live nodes: only this node"
fi
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}MESH IS HEALTHY${NC}"
    exit 0
elif [ "$FAILED" -le 3 ]; then
    echo -e "  ${YELLOW}${BOLD}MESH HAS ISSUES${NC} — review failures above"
    exit 1
else
    echo -e "  ${RED}${BOLD}MESH IS DEGRADED${NC} — multiple failures detected"
    exit 1
fi
