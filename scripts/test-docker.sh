#!/bin/bash
# Nightwatch — Docker services test (tests RUNNING services)
#
# Tests:
#   1. All containers running
#   2. Health checks passing
#   3. IRC server accepting connections
#   4. Bridge /health endpoint
#   5. Nginx serving frontend
#   6. Nginx proxying WebSocket path
#   7. No fatal errors in logs
#
# Usage: ./scripts/test-docker.sh

set -euo pipefail

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

pass() { ((PASSED++)); echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { ((FAILED++)); echo -e "  ${RED}[FAIL]${NC} $1"; }
skip() { ((SKIPPED++)); echo -e "  ${YELLOW}[SKIP]${NC} $1"; }
section() { echo ""; echo -e "${BOLD}${CYAN}== $1 ==${NC}"; }

echo "======================================"
echo "  Nightwatch Docker Tests"
echo "======================================"

# ---- Pre-flight ----

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}docker not found${NC}"
    exit 1
fi

# Check services are running
RUNNING=$(docker ps --format '{{.Names}}' 2>/dev/null | wc -l)
if [ "$RUNNING" -eq 0 ]; then
    echo -e "${RED}No Docker containers running. Run 'make run' first.${NC}"
    exit 1
fi

# ============================================================
# 1. Container Status
# ============================================================

section "1. Container Status"

for svc in ngircd irc-bridge nginx; do
    status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    if [ "$status" = "running" ]; then
        uptime=$(docker inspect --format='{{.State.StartedAt}}' "$svc" 2>/dev/null | cut -dT -f1,2 || echo "?")
        pass "$svc is running (since $uptime)"
    else
        fail "$svc status: $status"
    fi
done

# ============================================================
# 2. Health Checks
# ============================================================

section "2. Health Checks"

for svc in ngircd irc-bridge nginx; do
    health=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "none")
    if [ "$health" = "healthy" ]; then
        pass "$svc: healthy"
    elif [ "$health" = "starting" ]; then
        # Wait up to 30s
        echo "  Waiting for $svc..."
        for _ in $(seq 1 6); do
            sleep 5
            health=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "none")
            [ "$health" = "healthy" ] && break
        done
        if [ "$health" = "healthy" ]; then
            pass "$svc: healthy"
        else
            fail "$svc: $health (after 30s)"
        fi
    else
        fail "$svc: $health"
    fi
done

# ============================================================
# 3. IRC Server
# ============================================================

section "3. IRC Server"

# Port listening
if nc -z localhost 6667 2>/dev/null; then
    pass "IRC port 6667 accepting connections"
else
    fail "IRC port 6667 not reachable"
fi

# IRC protocol response
IRC_RESP=$(echo "QUIT" | nc -w 3 localhost 6667 2>/dev/null | head -1 || echo "")
if echo "$IRC_RESP" | grep -qi "irc\|ngircd\|nightwatch"; then
    pass "IRC server responds with valid protocol"
else
    if [ -n "$IRC_RESP" ]; then
        pass "IRC server responds: $(echo "$IRC_RESP" | cut -c1-60)"
    else
        fail "IRC server no response"
    fi
fi

# ============================================================
# 4. Bridge Service
# ============================================================

section "4. IRC Bridge"

# Health endpoint
BRIDGE_PORT=$(docker port irc-bridge 2>/dev/null | grep 3000 | head -1 | awk -F: '{print $NF}' || echo "8080")
HEALTH=$(curl -sf --max-time 3 "http://localhost:${BRIDGE_PORT}/health" 2>/dev/null || echo "")
if [ "$HEALTH" = "OK" ]; then
    pass "Bridge /health returns OK (port $BRIDGE_PORT)"
else
    fail "Bridge /health returned: '$HEALTH' (port $BRIDGE_PORT)"
fi

# WebSocket endpoint (should get upgrade required or bad request)
WS_RESP=$(curl -sf --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:${BRIDGE_PORT}/ws" 2>/dev/null || echo "000")
if [ "$WS_RESP" = "400" ] || [ "$WS_RESP" = "426" ] || [ "$WS_RESP" = "200" ]; then
    pass "Bridge /ws endpoint responds (HTTP $WS_RESP)"
else
    fail "Bridge /ws returned HTTP $WS_RESP"
fi

# ============================================================
# 5. Nginx
# ============================================================

section "5. Nginx Web Server"

NGINX_PORT=$(docker port nginx 2>/dev/null | grep 80 | head -1 | awk -F: '{print $NF}' || echo "80")

# Serves HTML
NGINX_RESP=$(curl -sf --max-time 3 "http://localhost:${NGINX_PORT}/" 2>/dev/null || echo "")
if echo "$NGINX_RESP" | grep -qi "nightwatch\|html"; then
    pass "Nginx serves Nightwatch frontend (port $NGINX_PORT)"
else
    fail "Nginx response does not contain expected content"
fi

# HTTP status
HTTP_CODE=$(curl -sf --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:${NGINX_PORT}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Nginx returns HTTP 200"
else
    fail "Nginx returned HTTP $HTTP_CODE"
fi

# Proxy to bridge
PROXY_CODE=$(curl -sf --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:${NGINX_PORT}/ws" 2>/dev/null || echo "000")
if [ "$PROXY_CODE" != "000" ] && [ "$PROXY_CODE" != "502" ] && [ "$PROXY_CODE" != "504" ]; then
    pass "Nginx proxies /ws to bridge (HTTP $PROXY_CODE)"
else
    fail "Nginx /ws proxy failed (HTTP $PROXY_CODE)"
fi

# ============================================================
# 6. Container Logs
# ============================================================

section "6. Container Logs (error check)"

for svc in ngircd irc-bridge nginx; do
    fatal_count=$(docker logs "$svc" 2>&1 | grep -ciE "fatal|panic|segfault|SIGSEGV" || true)
    error_count=$(docker logs "$svc" 2>&1 | grep -ciE "^error|ERROR" || true)
    if [ "$fatal_count" -eq 0 ]; then
        if [ "$error_count" -gt 5 ]; then
            skip "$svc: no fatal errors ($error_count warnings)"
        else
            pass "$svc: no fatal errors"
        fi
    else
        fail "$svc: $fatal_count fatal/panic entries in logs"
    fi
done

# ============================================================
# 7. Docker Network
# ============================================================

section "7. Docker Network"

NETWORK=$(docker inspect --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' ngircd 2>/dev/null || echo "")
if [ -n "$NETWORK" ]; then
    pass "Containers on network: $NETWORK"
else
    fail "Could not detect Docker network"
fi

# Check all services on same network
for svc in irc-bridge nginx; do
    svc_net=$(docker inspect --format='{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$svc" 2>/dev/null || echo "")
    if [ "$svc_net" = "$NETWORK" ]; then
        pass "$svc on same network as ngircd"
    else
        fail "$svc on different network ($svc_net vs $NETWORK)"
    fi
done

# ============================================================
# Summary
# ============================================================

echo ""
echo "======================================"
echo "  Docker Test Results"
echo "======================================"
echo -e "  ${GREEN}Passed:  $PASSED${NC}"
echo -e "  ${RED}Failed:  $FAILED${NC}"
echo -e "  ${YELLOW}Skipped: $SKIPPED${NC}"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}ALL DOCKER TESTS PASSED${NC}"
    exit 0
else
    echo -e "  ${RED}${BOLD}DOCKER TESTS FAILED${NC}"
    exit 1
fi
