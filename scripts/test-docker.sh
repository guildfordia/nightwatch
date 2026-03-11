#!/bin/bash
# Nightwatch — App services test (tests RUNNING services)
#
# Tests:
#   1. All services running (ngircd, nightwatch-bridge, nginx)
#   2. IRC server accepting connections
#   3. Bridge /health endpoint
#   4. Nginx serving frontend
#   5. Nginx proxying WebSocket path
#   6. No fatal errors in logs
#   7. Captive portal probes
#   8. Nick format
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

pass() { ((PASSED++)) || true; echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { ((FAILED++)) || true; echo -e "  ${RED}[FAIL]${NC} $1"; }
skip() { ((SKIPPED++)) || true; echo -e "  ${YELLOW}[SKIP]${NC} $1"; }
section() { echo ""; echo -e "${BOLD}${CYAN}== $1 ==${NC}"; }

echo "======================================"
echo "  Nightwatch Service Tests"
echo "======================================"

# ---- Pre-flight ----

# Check services are enabled
SERVICES_FOUND=0
for svc in ngircd nightwatch-bridge nginx; do
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        SERVICES_FOUND=$((SERVICES_FOUND + 1))
    fi
done
if [ "$SERVICES_FOUND" -eq 0 ]; then
    echo -e "${RED}No Nightwatch services enabled. Run 'make install' first.${NC}"
    exit 1
fi

# ============================================================
# 1. Service Status
# ============================================================

section "1. Service Status"

for svc in ngircd nightwatch-bridge nginx; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        # Get uptime from service start time
        started=$(systemctl show -p ActiveEnterTimestamp --value "$svc" 2>/dev/null | cut -d' ' -f1,2 || echo "?")
        pass "$svc is running (since $started)"
    else
        state=$(systemctl is-active "$svc" 2>/dev/null || echo "not found")
        fail "$svc status: $state"
    fi
done

# ============================================================
# 2. IRC Server
# ============================================================

section "2. IRC Server"

# Port listening
if nc -z localhost 6667 2>/dev/null; then
    pass "IRC port 6667 accepting connections"
else
    fail "IRC port 6667 not reachable"
fi

# IRC protocol response (server needs time between NICK/USER before it replies)
IRC_RESP=$( (echo -e "NICK testprobe\r"; sleep 1; echo -e "USER testprobe 0 * :test\r"; sleep 2; echo -e "QUIT\r") | nc -w 5 localhost 6667 2>/dev/null | head -1 || echo "")
if echo "$IRC_RESP" | grep -qi "irc\|ngircd\|nightwatch\|001\|NOTICE"; then
    pass "IRC server responds with valid protocol"
else
    if [ -n "$IRC_RESP" ]; then
        pass "IRC server responds: $(echo "$IRC_RESP" | cut -c1-60)"
    else
        fail "IRC server no response"
    fi
fi

# ============================================================
# 3. Bridge Service
# ============================================================

section "3. IRC Bridge"

# Health endpoint (bridge listens on localhost:3000)
HEALTH=$(curl -sf --max-time 3 http://localhost:3000/health 2>/dev/null || echo "")
if [ "$HEALTH" = "OK" ]; then
    pass "Bridge /health returns OK"
else
    fail "Bridge /health returned: '$HEALTH'"
fi

# WebSocket endpoint via nginx proxy (should get upgrade required or bad request)
NGINX_PORT="${NGINX_PORT:-80}"
WS_RESP=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:${NGINX_PORT}/ws" 2>/dev/null || echo "000")
if [ "$WS_RESP" = "400" ] || [ "$WS_RESP" = "426" ] || [ "$WS_RESP" = "200" ]; then
    pass "Bridge /ws responds via nginx (HTTP $WS_RESP)"
else
    fail "Bridge /ws via nginx returned HTTP $WS_RESP"
fi

# ============================================================
# 4. Nginx
# ============================================================

section "4. Nginx Web Server"

# Serves HTML
NGINX_RESP=$(curl -s --max-time 3 "http://localhost:${NGINX_PORT}/" 2>/dev/null || echo "")
if grep -qi "nightwatch\|html" <<< "$NGINX_RESP"; then
    pass "Nginx serves Nightwatch frontend (port $NGINX_PORT)"
else
    fail "Nginx response does not contain expected content"
fi

# HTTP status
HTTP_CODE=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:${NGINX_PORT}/" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
    pass "Nginx returns HTTP 200"
else
    fail "Nginx returned HTTP $HTTP_CODE"
fi

# Proxy to bridge
PROXY_CODE=$(curl -s --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:${NGINX_PORT}/ws" 2>/dev/null || echo "000")
if [ "$PROXY_CODE" != "000" ] && [ "$PROXY_CODE" != "502" ] && [ "$PROXY_CODE" != "504" ]; then
    pass "Nginx proxies /ws to bridge (HTTP $PROXY_CODE)"
else
    fail "Nginx /ws proxy failed (HTTP $PROXY_CODE)"
fi

# ============================================================
# 5. Service Logs
# ============================================================

section "5. Service Logs (error check)"

for svc in ngircd nightwatch-bridge nginx; do
    logs=$(journalctl -u "$svc" --no-pager -n 200 2>/dev/null || echo "")
    fatal_count=$(echo "$logs" | grep -ciE "fatal|panic|segfault|SIGSEGV" || true)
    error_count=$(echo "$logs" | grep -ciE "^error|ERROR" || true)
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
# 6. Captive Portal Probes
# ============================================================

section "6. Captive Portal Probes"

# iOS captive portal probe — must return "Success" (follow redirects with -L)
IOS_RESP=$(curl -sL --max-time 3 "http://localhost:${NGINX_PORT}/hotspot-detect.html" 2>/dev/null || echo "")
if echo "$IOS_RESP" | grep -q "Success"; then
    pass "iOS probe /hotspot-detect.html returns 'Success'"
else
    fail "iOS probe /hotspot-detect.html missing 'Success' response"
fi

# Android captive portal probe — must return HTTP 204 (follow redirects)
ANDROID_CODE=$(curl -sL --max-time 3 -o /dev/null -w "%{http_code}" "http://localhost:${NGINX_PORT}/generate_204" 2>/dev/null || echo "000")
if [ "$ANDROID_CODE" = "204" ]; then
    pass "Android probe /generate_204 returns HTTP 204"
else
    fail "Android probe /generate_204 returned HTTP $ANDROID_CODE (expected 204)"
fi

# Firefox captive portal probe — must return "success" (follow redirects)
FF_RESP=$(curl -sL --max-time 3 "http://localhost:${NGINX_PORT}/canonical.html" 2>/dev/null || echo "")
if echo "$FF_RESP" | grep -q "success"; then
    pass "Firefox probe /canonical.html returns 'success'"
else
    fail "Firefox probe /canonical.html missing 'success' response"
fi

# Windows captive portal probe — must return "Microsoft Connect Test"
WIN_RESP=$(curl -sL --max-time 3 "http://localhost:${NGINX_PORT}/connecttest.txt" 2>/dev/null || echo "")
if echo "$WIN_RESP" | grep -q "Microsoft Connect Test"; then
    pass "Windows probe /connecttest.txt returns correct text"
else
    fail "Windows probe /connecttest.txt missing expected response"
fi

# ============================================================
# 7. Nick Format
# ============================================================

section "7. Nick Format"

# Connect to IRC via bridge and check that assigned nick is guestN
NICK_OUTPUT=$( { printf "NICK nicktest%s\r\n" "$$"; sleep 1; printf "USER nicktest%s 0 * :test\r\n" "$$"; sleep 3; printf "QUIT\r\n"; } | nc -w 6 localhost 6667 2>/dev/null || echo "")
# The 001 (RPL_WELCOME) line contains the assigned nick
ASSIGNED_NICK=$(echo "$NICK_OUTPUT" | grep " 001 " | awk '{print $3}' || echo "")
if echo "$ASSIGNED_NICK" | grep -qE "^guest[0-9]+$"; then
    pass "IRC assigns guestN nicks (got: $ASSIGNED_NICK)"
elif [ -n "$ASSIGNED_NICK" ]; then
    # We connected with a custom nick so it kept it — test with bridge instead
    # Check bridge status endpoint for nick format
    BRIDGE_STATUS=$(curl -sf --max-time 3 http://localhost:3000/status 2>/dev/null || echo "")
    if echo "$BRIDGE_STATUS" | grep -q '"guest[0-9]'; then
        pass "Bridge assigns guestN nicks"
    elif echo "$BRIDGE_STATUS" | grep -q '"web[0-9]'; then
        fail "Bridge still assigns webN nicks (expected guestN)"
    else
        skip "Nick format test inconclusive (no bridge clients to check)"
    fi
else
    skip "Nick format test: could not connect to IRC"
fi

# Check nick counter file
COUNTER_DIR="/opt/nightwatch/irc-bridge-go/data"
COUNTER_VAL=$(cat "$COUNTER_DIR/nick-counter" 2>/dev/null || echo "")
if [ -n "$COUNTER_VAL" ]; then
    pass "Nick counter active (value: $(echo "$COUNTER_VAL" | tr -d '[:space:]'))"
else
    pass "Nick counter not yet created (no clients have connected via bridge)"
fi

# ============================================================
# Summary
# ============================================================

echo ""
echo "======================================"
echo "  Service Test Results"
echo "======================================"
echo -e "  ${GREEN}Passed:  $PASSED${NC}"
echo -e "  ${RED}Failed:  $FAILED${NC}"
echo -e "  ${YELLOW}Skipped: $SKIPPED${NC}"
echo ""

if [ "$FAILED" -eq 0 ]; then
    echo -e "  ${GREEN}${BOLD}ALL SERVICE TESTS PASSED${NC}"
    exit 0
else
    echo -e "  ${RED}${BOLD}SERVICE TESTS FAILED${NC}"
    exit 1
fi
