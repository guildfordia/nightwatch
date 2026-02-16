#!/bin/bash
# Nightwatch — Mesh network integration test
# Run from any node in the mesh to verify full connectivity
#
# Tests:
#   1. Local mesh health (batman-adv, 802.11s, interfaces)
#   2. Node discovery (ping all configured nodes, find who's online)
#   3. batman-adv topology (neighbors, originators)
#   4. Docker services (local + remote live nodes)
#   5. IRC cross-node messaging (if >1 node online)
#   6. Access point status
#   7. Gateway / internet connectivity
#   8. Local Docker container health
#
# Usage: sudo ./scripts/test-mesh.sh [--quick]
#   --quick  Skip slow tests (cross-node IRC, latency matrix)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

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

# ---- Load config ----

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${RED}Error: $ENV_FILE not found${NC}"
    exit 1
fi

set -o allexport
# shellcheck source=/dev/null
source "$ENV_FILE"
set +o allexport

BAT_IFACE="${BAT_IFACE:-bat0}"
MESH_IFACE="${MESH_IFACE:-wlan1}"
AP_IFACE="${AP_IFACE:-wlan0}"
IRC_PORT="${IRC_PORT:-6667}"
BRIDGE_PORT="${BRIDGE_PORT:-8080}"
NGINX_PORT="${NGINX_PORT:-80}"
LOCAL_IP="${MESH_IP%/*}"

# Node list: all possible mesh IPs (192.168.199.101-120, max 20 nodes)
declare -a NODE_IPS=()
declare -a NODE_NAMES=()
for i in $(seq 1 20); do
    NODE_IPS+=("192.168.199.$((100 + i))")
    NODE_NAMES+=("node${i}")
done

echo "======================================"
echo "  Nightwatch Mesh Integration Test"
echo "======================================"
echo ""
echo "  This node:  $LOCAL_IP (node #${PI_NUMBER:-?})"
echo "  Scanning:   192.168.199.101-120 (max 20 nodes)"
echo "  Mode:       $([ "$QUICK_MODE" = true ] && echo 'quick' || echo 'full')"
echo ""

# ---- Check we're running as root ----

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${YELLOW}Warning: some tests require root. Run with sudo for full coverage.${NC}"
    echo ""
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

bat_ip=$(ip -4 addr show dev "$BAT_IFACE" 2>/dev/null | grep -oP 'inet \K[0-9.]+' || echo "")
if [ -n "$bat_ip" ]; then
    pass "$BAT_IFACE has IP: $bat_ip"
    if [ "$bat_ip" = "$LOCAL_IP" ]; then
        pass "$BAT_IFACE IP matches MESH_IP ($LOCAL_IP)"
    else
        fail "$BAT_IFACE IP ($bat_ip) does not match MESH_IP ($LOCAL_IP)"
    fi
else
    fail "$BAT_IFACE has no IPv4 address"
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
if [ "${MESH_GATEWAY:-false}" = "true" ]; then
    if echo "$gw_mode" | grep -qi "server"; then
        pass "Gateway mode: server (as configured)"
    else
        fail "Gateway mode should be 'server' but got: $gw_mode"
    fi
else
    if echo "$gw_mode" | grep -qi "client\|off"; then
        pass "Gateway mode: client (as configured)"
    else
        warn "Gateway mode unexpected: $gw_mode"
    fi
fi

# ============================================================
# 2. Node Discovery
# ============================================================

section "2. Node Discovery"

# Check for node/IP conflicts
CONFLICT_FILE="/tmp/nightwatch-conflict"
if [ -f "$CONFLICT_FILE" ]; then
    fail "NODE CONFLICT: $(cat "$CONFLICT_FILE")"
else
    pass "No node conflicts detected"
fi

# Check if discovery daemon is running
if systemctl is-active nightwatch-discovery.service >/dev/null 2>&1; then
    pass "Discovery daemon running"
    PEER_FILE="/tmp/nightwatch-peers"
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

echo "  Scanning 192.168.199.101-120..."
for idx in "${!NODE_IPS[@]}"; do
    ip="${NODE_IPS[$idx]}"
    name="${NODE_NAMES[$idx]}"

    # Skip self
    if [ "$ip" = "$LOCAL_IP" ]; then
        continue
    fi

    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
        rtt=$(ping -c 1 -W 1 "$ip" 2>/dev/null | grep 'time=' | sed 's/.*time=//' || echo "?")
        echo -e "  ${GREEN}[ONLINE]${NC}  $ip ($name) — ${rtt}"
        LIVE_IPS+=("$ip")
        LIVE_NAMES+=("$name")
    fi
done

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
elif [ ${#LIVE_IPS[@]} -gt 0 ]; then
    fail "No batman-adv mesh neighbors (but live nodes exist)"
else
    skip "No batman-adv neighbors (no other nodes online)"
fi

# Originators — count only best routes (* prefix = unique originator)
originator_output=$(batctl meshif "$BAT_IFACE" o 2>/dev/null || batctl o 2>/dev/null || true)
originator_count=$(echo "$originator_output" | grep -c "^ \*" || true)
originator_count=$((originator_count + 0))
if [ "$originator_count" -gt 0 ]; then
    pass "batman-adv sees $originator_count originator(s) in mesh"
elif [ ${#LIVE_IPS[@]} -gt 0 ]; then
    fail "No batman-adv originators (but live nodes exist)"
else
    skip "No batman-adv originators (no other nodes online)"
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

        result=$(ping -c 5 -W 2 -I "$BAT_IFACE" "$ip" 2>/dev/null | tail -1 || echo "")
        if echo "$result" | grep -q "/"; then
            min=$(echo "$result" | awk -F'/' '{print $4}')
            avg=$(echo "$result" | awk -F'/' '{print $5}')
            max=$(echo "$result" | awk -F'/' '{print $6}')
            loss=$(ping -c 5 -W 2 -I "$BAT_IFACE" "$ip" 2>/dev/null | grep "packet loss" | awk -F',' '{print $3}' | tr -d ' ')
            echo -e "    → $ip ($name): min=${min}ms avg=${avg}ms max=${max}ms $loss"
            # Flag high latency
            avg_int=${avg%.*}
            if [ "${avg_int:-0}" -gt 100 ]; then
                warn "$ip latency high (${avg}ms avg)"
            fi
        else
            echo -e "    → $ip ($name): ${RED}unreachable over bat0${NC}"
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
# 6. Docker Services (local + live remote nodes)
# ============================================================

section "6. Docker Services"

# Local services
echo -e "  ${BOLD}$LOCAL_IP (this node) — local:${NC}"

if nc -z localhost "$IRC_PORT" 2>/dev/null; then
    pass "  IRC (port $IRC_PORT) listening"
else
    fail "  IRC (port $IRC_PORT) not reachable"
fi

health=$(curl -sf --max-time 3 "http://localhost:${BRIDGE_PORT}/health" 2>/dev/null || echo "")
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

    health=$(curl -sf --max-time 5 "http://${ip}:${BRIDGE_PORT}/health" 2>/dev/null || echo "")
    if [ "$health" = "OK" ]; then
        pass "  Bridge /health returns OK"
    else
        fail "  Bridge /health: '$health'"
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
        echo "  Testing: send on $LOCAL_IP → verify on $REMOTE_IP ($REMOTE_NAME)"

        TEST_MSG="MESHTEST_$(date +%s)_$$"
        TEST_NICK="testbot$$"

        # Start RECEIVER first on remote node — give it time to connect and join
        RECV_OUTPUT=$(mktemp)
        {
            echo "NICK recvbot$$"
            echo "USER recvbot$$ 0 * :Mesh Recv Bot"
            sleep 3
            echo "JOIN #nightwatch"
            sleep 10
            echo "QUIT :recv done"
        } | nc -w 15 "$REMOTE_IP" "$IRC_PORT" > "$RECV_OUTPUT" 2>&1 &
        RECV_PID=$!

        # Wait for receiver to connect and join channel
        sleep 5

        # Then SEND on local node
        {
            echo "NICK $TEST_NICK"
            echo "USER $TEST_NICK 0 * :Mesh Test Bot"
            sleep 2
            echo "JOIN #nightwatch"
            sleep 1
            echo "PRIVMSG #nightwatch :$TEST_MSG"
            sleep 2
            echo "QUIT :test done"
        } | nc -w 8 localhost "$IRC_PORT" >/dev/null 2>&1 &
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

section "8. Access Point"

if pgrep -x hostapd >/dev/null 2>&1; then
    pass "hostapd is running"

    ap_ssid="${AP_SSID:-Nightwatch}"
    # Check if AP interface is in batman
    if echo "$bat_ifaces" | grep -q "$AP_IFACE"; then
        pass "$AP_IFACE is bridged into batman-adv"
    else
        fail "$AP_IFACE not bridged into batman-adv (clients won't reach mesh)"
    fi

    # Count connected clients
    client_count=$(iw dev "$AP_IFACE" station dump 2>/dev/null | grep -c "^Station" || true)
    client_count=$((client_count + 0))
    if [ "$client_count" -gt 0 ]; then
        pass "$client_count client(s) connected to AP '$ap_ssid'"
    else
        skip "No clients currently connected to AP '$ap_ssid'"
    fi
else
    fail "hostapd is not running (AP is down)"
fi

# ============================================================
# 9. Gateway & Internet
# ============================================================

section "9. Gateway & Internet"

if [ "${MESH_GATEWAY:-false}" = "true" ]; then
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
# 10. Local Docker Health
# ============================================================

section "10. Local Docker Health"

for svc in ngircd irc-bridge nginx; do
    status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    health=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "none")

    if [ "$status" = "running" ] && [ "$health" = "healthy" ]; then
        pass "$svc: running + healthy"
    elif [ "$status" = "running" ]; then
        warn "$svc: running but health=$health"
    else
        fail "$svc: status=$status"
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
