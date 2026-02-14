#!/bin/bash
# Nightwatch — Mesh network integration test
# Run from any node in the mesh to verify full connectivity
#
# Tests:
#   1. Local mesh health (batman-adv, 802.11s, interfaces)
#   2. Node-to-node reachability (ping over bat0)
#   3. batman-adv topology (neighbors, originators)
#   4. Docker services on all nodes (IRC, bridge, nginx)
#   5. IRC cross-node messaging (send on this node, verify on remote)
#   6. Access point status
#   7. Gateway / internet connectivity
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

pass()    { ((PASSED++));   echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail()    { ((FAILED++));   echo -e "  ${RED}[FAIL]${NC} $1"; }
skip()    { ((SKIPPED++));  echo -e "  ${YELLOW}[SKIP]${NC} $1"; }
warn()    { ((WARNINGS++)); echo -e "  ${YELLOW}[WARN]${NC} $1"; }
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

# Build node list from .env (PI1_MESH_IP, PI2_MESH_IP, ...)
declare -a NODE_IPS=()
declare -a NODE_NAMES=()
for i in $(seq 1 20); do
    ip_var="PI${i}_MESH_IP"
    name_var="PI${i}_SERVER_NAME"
    ip="${!ip_var:-}"
    name="${!name_var:-node${i}}"
    if [ -n "$ip" ]; then
        NODE_IPS+=("$ip")
        NODE_NAMES+=("$name")
    fi
done

if [ ${#NODE_IPS[@]} -eq 0 ]; then
    echo -e "${RED}No nodes configured in .env (PI*_MESH_IP)${NC}"
    exit 1
fi

echo "======================================"
echo "  Nightwatch Mesh Integration Test"
echo "======================================"
echo ""
echo "  This node:   $LOCAL_IP (Pi #${PI_NUMBER:-?})"
echo "  Nodes in .env: ${#NODE_IPS[@]}"
echo "  Mode:        $([ "$QUICK_MODE" = true ] && echo 'quick' || echo 'full')"
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

# batman-adv module loaded
if lsmod | grep -q batman_adv; then
    version=$(cat /sys/module/batman_adv/version 2>/dev/null || echo "unknown")
    pass "batman-adv module loaded (v$version)"
else
    fail "batman-adv module not loaded"
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
if [ "$MESH_GATEWAY" = "true" ]; then
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
# 2. 802.11s Mesh Peers
# ============================================================

section "2. 802.11s Mesh Peers"

peer_count=$(iw dev "$MESH_IFACE" station dump 2>/dev/null | grep -c "^Station" || echo "0")
expected_peers=$((${#NODE_IPS[@]} - 1))

if [ "$peer_count" -gt 0 ]; then
    pass "802.11s has $peer_count mesh peer(s)"
else
    fail "No 802.11s mesh peers found"
fi

# Check peer link states
established=$(iw dev "$MESH_IFACE" station dump 2>/dev/null | grep "mesh plink:" | grep -c "ESTAB" || echo "0")
if [ "$established" -gt 0 ]; then
    pass "$established peer link(s) ESTABLISHED"
else
    fail "No established peer links"
fi

if [ "$peer_count" -ge "$expected_peers" ]; then
    pass "Peer count ($peer_count) >= expected ($expected_peers)"
else
    warn "Peer count ($peer_count) < expected ($expected_peers) — some nodes may be multi-hop"
fi

# ============================================================
# 3. batman-adv Topology
# ============================================================

section "3. batman-adv Topology"

# Neighbors (direct links)
neighbor_count=$(batctl meshif "$BAT_IFACE" n 2>/dev/null | grep -cv "^\[B.A.T.M.A.N\|^$\|IF" || \
                 batctl n 2>/dev/null | grep -cv "^\[B.A.T.M.A.N\|^$\|IF" || echo "0")
if [ "$neighbor_count" -gt 0 ]; then
    pass "batman-adv has $neighbor_count direct neighbor(s)"
else
    fail "No batman-adv neighbors"
fi

# Originators (full mesh view)
originator_count=$(batctl meshif "$BAT_IFACE" o 2>/dev/null | grep -cv "^\[B.A.T.M.A.N\|^$\|Originator" || \
                   batctl o 2>/dev/null | grep -cv "^\[B.A.T.M.A.N\|^$\|Originator" || echo "0")
if [ "$originator_count" -gt 0 ]; then
    pass "batman-adv sees $originator_count originator(s) in mesh"
else
    fail "No batman-adv originators (mesh has no routes)"
fi

# Gateway list
gw_list=$(batctl meshif "$BAT_IFACE" gwl 2>/dev/null || batctl gwl 2>/dev/null || echo "")
gw_count=$(echo "$gw_list" | grep -cv "^\[B.A.T.M.A.N\|^$\|Gateway" || echo "0")
if [ "$gw_count" -gt 0 ]; then
    pass "batman-adv sees $gw_count gateway(s)"
elif [ "$MESH_GATEWAY" = "true" ]; then
    warn "This node is a gateway but no gateways in list (may need time)"
else
    skip "No gateways in mesh (none configured)"
fi

# ============================================================
# 4. Node-to-Node Reachability
# ============================================================

section "4. Node-to-Node Reachability (ping over $BAT_IFACE)"

reachable=0
unreachable=0

for idx in "${!NODE_IPS[@]}"; do
    ip="${NODE_IPS[$idx]}"
    name="${NODE_NAMES[$idx]}"

    if [ "$ip" = "$LOCAL_IP" ]; then
        pass "$ip ($name) — this node"
        ((reachable++))
        continue
    fi

    if ping -c 2 -W 2 -I "$BAT_IFACE" "$ip" >/dev/null 2>&1; then
        rtt=$(ping -c 3 -W 2 -I "$BAT_IFACE" "$ip" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
        pass "$ip ($name) — reachable (avg ${rtt}ms)"
        ((reachable++))
    else
        fail "$ip ($name) — UNREACHABLE"
        ((unreachable++))
    fi
done

echo ""
echo -e "  Reachable: $reachable/${#NODE_IPS[@]}  Unreachable: $unreachable"

# ============================================================
# 5. Latency Matrix (full mode only)
# ============================================================

if [ "$QUICK_MODE" = false ] && [ ${#NODE_IPS[@]} -gt 1 ]; then
    section "5. Latency Matrix"

    echo "  From this node ($LOCAL_IP):"
    for idx in "${!NODE_IPS[@]}"; do
        ip="${NODE_IPS[$idx]}"
        name="${NODE_NAMES[$idx]}"
        [ "$ip" = "$LOCAL_IP" ] && continue

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
            echo -e "    → $ip ($name): ${RED}unreachable${NC}"
        fi
    done
else
    section "5. Latency Matrix"
    skip "Skipped (use full mode: sudo ./scripts/test-mesh.sh)"
fi

# ============================================================
# 6. Docker Services on All Nodes
# ============================================================

section "6. Docker Services Across Mesh"

for idx in "${!NODE_IPS[@]}"; do
    ip="${NODE_IPS[$idx]}"
    name="${NODE_NAMES[$idx]}"

    if [ "$ip" = "$LOCAL_IP" ]; then
        # Test local services directly
        echo -e "  ${BOLD}$ip ($name) — local:${NC}"

        # ngircd
        if nc -z localhost "$IRC_PORT" 2>/dev/null; then
            pass "  IRC (port $IRC_PORT) listening"
        else
            fail "  IRC (port $IRC_PORT) not reachable"
        fi

        # irc-bridge health
        health=$(curl -sf --max-time 3 "http://localhost:${BRIDGE_PORT}/health" 2>/dev/null || echo "")
        if [ "$health" = "OK" ]; then
            pass "  Bridge /health returns OK"
        else
            fail "  Bridge /health returned: '$health'"
        fi

        # nginx
        if curl -sf --max-time 3 "http://localhost:${NGINX_PORT}/" >/dev/null 2>&1; then
            pass "  Nginx (port $NGINX_PORT) serves frontend"
        else
            fail "  Nginx (port $NGINX_PORT) not reachable"
        fi
    else
        echo -e "  ${BOLD}$ip ($name) — remote:${NC}"

        # IRC port
        if nc -z -w 3 "$ip" "$IRC_PORT" 2>/dev/null; then
            pass "  IRC (port $IRC_PORT) reachable"
        else
            fail "  IRC (port $IRC_PORT) not reachable"
        fi

        # Bridge health
        health=$(curl -sf --max-time 5 "http://${ip}:${BRIDGE_PORT}/health" 2>/dev/null || echo "")
        if [ "$health" = "OK" ]; then
            pass "  Bridge /health returns OK"
        else
            fail "  Bridge /health: '$health'"
        fi

        # Nginx frontend
        if curl -sf --max-time 5 "http://${ip}:${NGINX_PORT}/" 2>/dev/null | grep -qi "nightwatch"; then
            pass "  Nginx serves Nightwatch frontend"
        else
            fail "  Nginx (port $NGINX_PORT) not serving frontend"
        fi
    fi
done

# ============================================================
# 7. IRC Cross-Node Messaging
# ============================================================

if [ "$QUICK_MODE" = false ] && [ "$reachable" -gt 1 ]; then
    section "7. IRC Cross-Node Messaging"

    # Pick the first remote node that's reachable
    REMOTE_IP=""
    REMOTE_NAME=""
    for idx in "${!NODE_IPS[@]}"; do
        ip="${NODE_IPS[$idx]}"
        [ "$ip" = "$LOCAL_IP" ] && continue
        if nc -z -w 2 "$ip" "$IRC_PORT" 2>/dev/null; then
            REMOTE_IP="$ip"
            REMOTE_NAME="${NODE_NAMES[$idx]}"
            break
        fi
    done

    if [ -z "$REMOTE_IP" ]; then
        skip "No remote IRC server reachable for cross-node test"
    else
        echo "  Testing: send on $LOCAL_IP → verify on $REMOTE_IP ($REMOTE_NAME)"

        TEST_MSG="MESHTEST_$(date +%s)_$$"
        TEST_NICK="testbot$$"

        # Connect to LOCAL IRC, join channel, send test message
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

        # Connect to REMOTE IRC, join channel, listen for the test message
        RECV_OUTPUT=$(mktemp)
        {
            echo "NICK recvbot$$"
            echo "USER recvbot$$ 0 * :Mesh Recv Bot"
            sleep 2
            echo "JOIN #nightwatch"
            sleep 5
            echo "QUIT :recv done"
        } | nc -w 10 "$REMOTE_IP" "$IRC_PORT" > "$RECV_OUTPUT" 2>&1 &
        RECV_PID=$!

        # Wait for both to finish
        wait $SEND_PID 2>/dev/null || true
        wait $RECV_PID 2>/dev/null || true

        # Check if remote received the message
        if grep -q "$TEST_MSG" "$RECV_OUTPUT" 2>/dev/null; then
            pass "Message delivered across mesh: $LOCAL_IP → $REMOTE_IP"
        else
            # The receiver might have joined after the message — try reverse
            fail "Message not received on $REMOTE_IP (IRC federation may need time)"
            echo -e "    ${YELLOW}Hint: ensure ngircd servers are linked (make setup-distributed-irc)${NC}"
        fi

        rm -f "$RECV_OUTPUT"
    fi
elif [ "$QUICK_MODE" = true ]; then
    section "7. IRC Cross-Node Messaging"
    skip "Skipped in quick mode"
else
    section "7. IRC Cross-Node Messaging"
    skip "Only one node reachable — cannot test cross-node"
fi

# ============================================================
# 8. Access Point Status
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
    client_count=$(iw dev "$AP_IFACE" station dump 2>/dev/null | grep -c "^Station" || echo "0")
    if [ "$client_count" -gt 0 ]; then
        pass "$client_count client(s) connected to AP '$ap_ssid'"
    else
        skip "No clients currently connected to AP '$ap_ssid'"
    fi
else
    fail "hostapd is not running (AP is down)"
fi

# ============================================================
# 9. Gateway / Internet
# ============================================================

section "9. Gateway & Internet"

if [ "$MESH_GATEWAY" = "true" ]; then
    echo "  This node is configured as gateway"

    # Check IP forwarding
    fwd=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "0")
    if [ "$fwd" = "1" ]; then
        pass "IP forwarding enabled"
    else
        fail "IP forwarding disabled (sysctl net.ipv4.ip_forward=0)"
    fi

    # Check NAT rules
    if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE"; then
        pass "NAT/MASQUERADE rule active"
    else
        fail "No MASQUERADE rule in iptables (internet sharing broken)"
    fi

    # Check internet access
    if ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
        pass "Internet reachable (8.8.8.8)"
    else
        fail "Internet not reachable from gateway"
    fi

    if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
        pass "DNS reachable (1.1.1.1)"
    else
        warn "Secondary DNS not reachable"
    fi
else
    # Non-gateway: check if a gateway is available
    if [ "$gw_count" -gt 0 ]; then
        pass "Gateway available in mesh ($gw_count gateway(s) advertised)"
        # Try to reach internet via mesh gateway
        if ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
            pass "Internet reachable via mesh gateway"
        else
            warn "Internet not reachable (gateway may not be sharing internet)"
        fi
    else
        skip "No gateway configured or advertised in mesh"
    fi
fi

# ============================================================
# 10. Docker Container Health
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
