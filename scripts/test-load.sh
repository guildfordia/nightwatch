#!/bin/bash
# Nightwatch — Multi-client load test
#
# Simulates N users on each node connecting to IRC, joining #nightwatch,
# and sending messages. Verifies cross-node delivery.
#
# Usage:
#   ./scripts/test-load.sh [clients_per_node] [messages_per_client]
#   ./scripts/test-load.sh 5 3      # 5 users per node, 3 messages each
#
# Requires: nc (netcat)

set -euo pipefail

CLIENTS_PER_NODE="${1:-5}"
MSGS_PER_CLIENT="${2:-3}"
NODE1="192.168.199.101"
NODE2="192.168.199.102"
CHANNEL="#nightwatch"
TIMEOUT=10
TMPDIR=$(mktemp -d /tmp/nightwatch-loadtest.XXXXX)
PASSED=0
FAILED=0
WARNINGS=0

trap 'cleanup' EXIT INT TERM HUP QUIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

cleanup() {
    # Kill all background jobs
    jobs -p 2>/dev/null | xargs kill 2>/dev/null || true
    # Small delay so processes close their connections
    sleep 1
    rm -rf "$TMPDIR"
}

log() { echo -e "$1"; }
pass() { log "  ${GREEN}[PASS]${NC} $1"; PASSED=$((PASSED + 1)); }
fail() { log "  ${RED}[FAIL]${NC} $1"; FAILED=$((FAILED + 1)); }
warn() { log "  ${YELLOW}[WARN]${NC} $1"; WARNINGS=$((WARNINGS + 1)); }

# How long the entire send phase lasts (all senders in parallel)
SEND_DURATION=$(( (MSGS_PER_CLIENT / 2) + 5 ))  # msgs * 0.5s sleep + margin

# Connect an IRC client, join channel, optionally send messages, log received
# Usage: irc_client <host> <nick> <logfile> [send_count] [send_prefix] [listen_time]
irc_client() {
    local host="$1" nick="$2" logfile="$3" send_count="${4:-0}" send_prefix="${5:-}" listen_time="${6:-$TIMEOUT}"

    {
        # Register
        echo "NICK $nick"
        echo "USER $nick 0 * :Load Test User"
        sleep 2
        echo "JOIN $CHANNEL"
        sleep 1

        # Send messages
        for i in $(seq 1 "$send_count"); do
            echo "PRIVMSG $CHANNEL :${send_prefix}msg-${i}-from-${nick}-$(date +%s%N)"
            sleep 0.5
        done

        # Listen for a while to collect messages
        sleep "$listen_time"

        echo "QUIT :loadtest done"
        sleep 0.5
    } | nc -w $((listen_time + 5)) "$host" 6667 > "$logfile" 2>/dev/null || true
}

echo ""
echo -e "${BOLD}======================================"
echo "  Nightwatch — Load Test"
echo "======================================${NC}"
echo ""
echo "  Nodes:              $NODE1, $NODE2"
echo "  Clients per node:   $CLIENTS_PER_NODE"
echo "  Messages per client: $MSGS_PER_CLIENT"
echo "  Total clients:      $((CLIENTS_PER_NODE * 2))"
echo "  Total messages:     $((CLIENTS_PER_NODE * 2 * MSGS_PER_CLIENT))"
echo ""

# ---- Check connectivity ----
log "${BOLD}${CYAN}== 1. Pre-flight checks ==${NC}"

if ping -c 1 -W 2 "$NODE1" >/dev/null 2>&1; then
    pass "Node 1 ($NODE1) reachable"
else
    fail "Node 1 ($NODE1) unreachable"
    exit 1
fi

if ping -c 1 -W 2 "$NODE2" >/dev/null 2>&1; then
    pass "Node 2 ($NODE2) reachable"
else
    fail "Node 2 ($NODE2) unreachable"
    exit 1
fi

if nc -z -w 2 "$NODE1" 6667 2>/dev/null; then
    pass "Node 1 IRC port open"
else
    fail "Node 1 IRC port closed"
    exit 1
fi

if nc -z -w 2 "$NODE2" 6667 2>/dev/null; then
    pass "Node 2 IRC port open"
else
    fail "Node 2 IRC port closed"
    exit 1
fi

# ---- Launch listeners on both nodes ----
log ""
log "${BOLD}${CYAN}== 2. Launching listener clients ==${NC}"

# One listener per node that collects all messages
LISTEN1="$TMPDIR/listen-node1.log"
LISTEN2="$TMPDIR/listen-node2.log"

# Listeners must stay alive for the entire send phase + collection buffer
LISTEN_TIME=$((SEND_DURATION + TIMEOUT + 10))

irc_client "$NODE1" "ear_n1" "$LISTEN1" 0 "" "$LISTEN_TIME" &
LISTEN1_PID=$!
irc_client "$NODE2" "ear_n2" "$LISTEN2" 0 "" "$LISTEN_TIME" &
LISTEN2_PID=$!

log "  Listeners started (ear_n1 on node1, ear_n2 on node2)"
sleep 3

# ---- Launch sender clients ----
log ""
log "${BOLD}${CYAN}== 3. Launching $((CLIENTS_PER_NODE * 2)) sender clients ==${NC}"

SENDER_PIDS=()

for i in $(seq 1 "$CLIENTS_PER_NODE"); do
    logfile="$TMPDIR/sender-n1-${i}.log"
    irc_client "$NODE1" "u1x${i}" "$logfile" "$MSGS_PER_CLIENT" "N1-" "$TIMEOUT" &
    SENDER_PIDS+=($!)
done
log "  Started $CLIENTS_PER_NODE senders on node 1"

for i in $(seq 1 "$CLIENTS_PER_NODE"); do
    logfile="$TMPDIR/sender-n2-${i}.log"
    irc_client "$NODE2" "u2x${i}" "$logfile" "$MSGS_PER_CLIENT" "N2-" "$TIMEOUT" &
    SENDER_PIDS+=($!)
done
log "  Started $CLIENTS_PER_NODE senders on node 2"

# ---- Wait for senders to finish ----
TOTAL_WAIT=$((SEND_DURATION + TIMEOUT + 8))
log ""
log "  Waiting ${TOTAL_WAIT}s for messages to flow..."

for pid in "${SENDER_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# Give listeners a moment to collect remaining messages
sleep 3

# Kill listeners
kill $LISTEN1_PID $LISTEN2_PID 2>/dev/null || true
wait $LISTEN1_PID 2>/dev/null || true
wait $LISTEN2_PID 2>/dev/null || true

# ---- Analyze results ----
log ""
log "${BOLD}${CYAN}== 4. Connection results ==${NC}"

# Check how many clients successfully joined
JOINED_N1=0
JOINED_N2=0
for f in "$TMPDIR"/sender-n1-*.log; do
    [ -f "$f" ] || continue
    if grep -qE " (JOIN |353 )" "$f" 2>/dev/null; then
        JOINED_N1=$((JOINED_N1 + 1))
    fi
done
for f in "$TMPDIR"/sender-n2-*.log; do
    [ -f "$f" ] || continue
    if grep -qE " (JOIN |353 )" "$f" 2>/dev/null; then
        JOINED_N2=$((JOINED_N2 + 1))
    fi
done

if [ "$JOINED_N1" -eq "$CLIENTS_PER_NODE" ]; then
    pass "All $CLIENTS_PER_NODE clients connected to node 1"
else
    fail "Only $JOINED_N1/$CLIENTS_PER_NODE clients connected to node 1"
fi

if [ "$JOINED_N2" -eq "$CLIENTS_PER_NODE" ]; then
    pass "All $CLIENTS_PER_NODE clients connected to node 2"
else
    fail "Only $JOINED_N2/$CLIENTS_PER_NODE clients connected to node 2"
fi

# Check nickname collisions
NICK_ERRORS=0
for f in "$TMPDIR"/sender-*.log; do
    [ -f "$f" ] || continue
    if grep -qE " (433|436) " "$f" 2>/dev/null; then
        NICK_ERRORS=$((NICK_ERRORS + 1))
    fi
done
if [ "$NICK_ERRORS" -eq 0 ]; then
    pass "No nickname collisions"
else
    fail "$NICK_ERRORS client(s) had nickname collisions"
fi

log ""
log "${BOLD}${CYAN}== 5. Message delivery ==${NC}"

# Expected messages per node = clients * messages_per_client
EXPECTED_PER_NODE=$((CLIENTS_PER_NODE * MSGS_PER_CLIENT))

log "  Expected per node: $EXPECTED_PER_NODE ($CLIENTS_PER_NODE clients x $MSGS_PER_CLIENT msgs)"

# Check cross-node delivery: N1 messages should appear on listener2, N2 on listener1
N1_ON_L2=$(grep -c "N1-msg-" "$LISTEN2" 2>/dev/null) || N1_ON_L2=0
N2_ON_L1=$(grep -c "N2-msg-" "$LISTEN1" 2>/dev/null) || N2_ON_L1=0

# Also count same-node delivery
N1_ON_L1=$(grep -c "N1-msg-" "$LISTEN1" 2>/dev/null) || N1_ON_L1=0
N2_ON_L2=$(grep -c "N2-msg-" "$LISTEN2" 2>/dev/null) || N2_ON_L2=0

log ""
log "  Cross-node delivery:"
log "    Node1→Node2: $N1_ON_L2 / $EXPECTED_PER_NODE messages received"
log "    Node2→Node1: $N2_ON_L1 / $EXPECTED_PER_NODE messages received"
log "  Same-node delivery:"
log "    Node1→Node1: $N1_ON_L1 / $EXPECTED_PER_NODE"
log "    Node2→Node2: $N2_ON_L2 / $EXPECTED_PER_NODE"

# Cross-node checks
if [ "$N1_ON_L2" -ge "$EXPECTED_PER_NODE" ]; then
    pass "All node1 messages delivered to node2 ($N1_ON_L2/$EXPECTED_PER_NODE)"
elif [ "$N1_ON_L2" -gt 0 ]; then
    warn "Partial delivery node1→node2: $N1_ON_L2/$EXPECTED_PER_NODE"
else
    fail "No messages from node1 reached node2"
fi

if [ "$N2_ON_L1" -ge "$EXPECTED_PER_NODE" ]; then
    pass "All node2 messages delivered to node1 ($N2_ON_L1/$EXPECTED_PER_NODE)"
elif [ "$N2_ON_L1" -gt 0 ]; then
    warn "Partial delivery node2→node1: $N2_ON_L1/$EXPECTED_PER_NODE"
else
    fail "No messages from node2 reached node1"
fi

# Same-node checks
if [ "$N1_ON_L1" -ge "$EXPECTED_PER_NODE" ]; then
    pass "All node1 messages received locally ($N1_ON_L1/$EXPECTED_PER_NODE)"
elif [ "$N1_ON_L1" -gt 0 ]; then
    warn "Partial local delivery on node1: $N1_ON_L1/$EXPECTED_PER_NODE"
else
    fail "No local message delivery on node1"
fi

if [ "$N2_ON_L2" -ge "$EXPECTED_PER_NODE" ]; then
    pass "All node2 messages received locally ($N2_ON_L2/$EXPECTED_PER_NODE)"
elif [ "$N2_ON_L2" -gt 0 ]; then
    warn "Partial local delivery on node2: $N2_ON_L2/$EXPECTED_PER_NODE"
else
    fail "No local message delivery on node2"
fi

# ---- Check for errors in logs ----
log ""
log "${BOLD}${CYAN}== 6. Error check ==${NC}"

ERROR_COUNT=0
for f in "$TMPDIR"/*.log; do
    [ -f "$f" ] || continue
    errors=$(grep -cE "ERROR| (451|462|463) " "$f" 2>/dev/null) || errors=0
    ERROR_COUNT=$((ERROR_COUNT + errors))
done

if [ "$ERROR_COUNT" -eq 0 ]; then
    pass "No IRC errors in client logs"
else
    warn "$ERROR_COUNT IRC error(s) found in logs"
    # Show first few errors
    grep -hE "ERROR| (451|462|463) " "$TMPDIR"/*.log 2>/dev/null | head -5 | while read -r line; do
        log "    $line"
    done
fi

# ---- Summary ----
TOTAL=$((PASSED + FAILED + WARNINGS))

echo ""
echo -e "${BOLD}======================================"
echo "  Load Test Results"
echo -e "======================================${NC}"
echo -e "  ${GREEN}Passed:   $PASSED${NC}"
echo -e "  ${RED}Failed:   $FAILED${NC}"
echo -e "  ${YELLOW}Warnings: $WARNINGS${NC}"
echo ""
echo "  Clients:  $((JOINED_N1 + JOINED_N2)) / $((CLIENTS_PER_NODE * 2)) connected"
echo "  Messages: $((N1_ON_L2 + N2_ON_L1)) / $((EXPECTED_PER_NODE * 2)) delivered cross-node"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}LOAD TEST PASSED${NC}"
else
    echo -e "  ${RED}${BOLD}LOAD TEST FAILED${NC}"
fi
echo ""

exit "$FAILED"
