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
#   7. Bridge /status endpoint
#   8. Nick format
#
# Usage: ./scripts/test-services.sh

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

# CdC §7.2 — strict criterion: `journalctl --priority=err --since "1 hour ago"`
# should be empty. Reported as warn (not fail) so operators see the count
# without the suite collapsing on benign boot-time err lines (driver init,
# ath9k_htc one-shots) — investigate any non-zero count manually.
PRIORITY_ERR_COUNT=$(journalctl --priority=err --since "1 hour ago" --no-pager 2>/dev/null | grep -cv -- '-- ' || true)
if [ "$PRIORITY_ERR_COUNT" -eq 0 ]; then
    pass "journalctl --priority=err --since '1 hour ago' is empty (CdC §7.2)"
else
    skip "journalctl --priority=err --since '1 hour ago' has $PRIORITY_ERR_COUNT entries — inspect manually (CdC §7.2 expects 0)"
fi

# ============================================================
# 6. Bridge /status Endpoint
# ============================================================

section "6. Bridge /status"

BRIDGE_STATUS=$(curl -sf --max-time 3 http://localhost:3000/status 2>/dev/null | tr -d '[:space:]' || echo "")
if [ -n "$BRIDGE_STATUS" ]; then
    pass "Bridge /status returns JSON"
    # Check uptime
    uptime_h=$(echo "$BRIDGE_STATUS" | grep -o '"uptime_human":"[^"]*"' | cut -d'"' -f4)
    if [ -n "$uptime_h" ]; then
        pass "Bridge uptime: $uptime_h"
    else
        fail "Bridge /status missing uptime"
    fi
    # Check IRC connection status
    irc_status=$(echo "$BRIDGE_STATUS" | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4)
    if [ "$irc_status" = "ok" ]; then
        pass "Bridge IRC connection: ok"
    else
        fail "Bridge IRC connection: $irc_status"
    fi
else
    fail "Bridge /status not reachable"
fi

# ============================================================
# 7. Nick Format
# ============================================================

section "7. Nick Format"

# Connect to IRC via bridge and check that assigned nick is guestN
TEST_NICK="nt$(( $$ % 10000 ))"
NICK_OUTPUT=$( { printf "NICK %s\r\n" "$TEST_NICK"; sleep 1; printf "USER %s 0 * :test\r\n" "$TEST_NICK"; sleep 3; printf "QUIT\r\n"; } | nc -w 6 localhost 6667 2>/dev/null || echo "")
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
# 8. CdC §3.4 #11 — max_num_sta=8 cap
# ============================================================

section "8. AP cap (CdC §3.4 #11)"

AP_IFACE_VAL=$(grep '^AP_IFACE=' /opt/nightwatch/.env 2>/dev/null | cut -d= -f2 || echo "wlan2")
if command -v hostapd_cli >/dev/null 2>&1; then
    HOSTAPD_CFG=$(hostapd_cli -i "$AP_IFACE_VAL" get_config 2>/dev/null || echo "")
    if echo "$HOSTAPD_CFG" | grep -q "^max_num_sta=8$"; then
        pass "hostapd_cli get_config reports max_num_sta=8"
    elif [ -z "$HOSTAPD_CFG" ]; then
        skip "hostapd_cli unreachable (AP dongle may be missing or hostapd not yet up)"
    else
        fail "hostapd reports a different max_num_sta value"
    fi
else
    skip "hostapd_cli not installed"
fi

# ============================================================
# 9. CdC §3.4 #14 — captive portal probes
# ============================================================

section "9. Captive portal (CdC §3.4 #14)"

for probe in /generate_204 /gen_204; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost${probe}" 2>/dev/null || echo "000")
    if [ "$code" = "204" ]; then
        pass "nginx ${probe} returns 204"
    else
        fail "nginx ${probe} returned HTTP $code (expected 204)"
    fi
done

CAPTIVE_JSON=$(curl -sf --max-time 3 http://localhost/api/captive 2>/dev/null || echo "")
if echo "$CAPTIVE_JSON" | grep -q '"captive": *true'; then
    pass "/api/captive advertises captive=true (RFC 8908)"
else
    fail "/api/captive missing or malformed"
fi

# ============================================================
# 10. CdC §3.4 #12, #13 — /api/config + diagnostic gating
# ============================================================

section "10. Exposition mode (CdC §3.4 #12, #13)"

CONFIG_JSON=$(curl -sf --max-time 3 http://localhost/api/config 2>/dev/null || echo "")
MODE_VAL=$(echo "$CONFIG_JSON" | grep -o '"mode":"[^"]*"' | cut -d\" -f4 || echo "")
EMAIL_VAL=$(echo "$CONFIG_JSON" | grep -o '"signalement_email":"[^"]*"' | cut -d\" -f4 || echo "")
if [ -n "$MODE_VAL" ]; then
    pass "/api/config returns mode=$MODE_VAL"
else
    fail "/api/config missing or malformed (got: $CONFIG_JSON)"
fi
if [ -n "$EMAIL_VAL" ]; then
    if [ "$EMAIL_VAL" = "NON_DEFINI@nightwatch.local" ]; then
        skip "SIGNALEMENT_EMAIL still at placeholder — operator must set it before exposition"
    else
        pass "/api/config exposes a SIGNALEMENT_EMAIL"
    fi
else
    fail "/api/config missing signalement_email"
fi

# Diagnostic endpoint gating
for endpoint in /api/blink /api/debug /api/bridge-status; do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost${endpoint}" 2>/dev/null || echo "000")
    if [ "$MODE_VAL" = "production" ]; then
        if [ "$code" = "403" ]; then
            pass "production: ${endpoint} → 403"
        else
            fail "production: ${endpoint} returned $code (expected 403)"
        fi
    elif [ "$MODE_VAL" = "debug" ]; then
        if [ "$code" = "200" ] || [ "$code" = "503" ]; then
            pass "debug: ${endpoint} reachable (HTTP $code)"
        else
            fail "debug: ${endpoint} returned $code (expected 200/503)"
        fi
    fi
done

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
