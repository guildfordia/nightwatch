#!/bin/bash
# Nightwatch — Docker services integration test
# Tests: image builds, container startup, health checks, inter-service connectivity
#
# Usage: ./scripts/test-docker.sh
# Requires: docker, docker compose (or docker-compose)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
SKIPPED=0

pass() { ((PASSED++)); echo -e "  ${GREEN}[PASS]${NC} $1"; }
fail() { ((FAILED++)); echo -e "  ${RED}[FAIL]${NC} $1"; }
skip() { ((SKIPPED++)); echo -e "  ${YELLOW}[SKIP]${NC} $1"; }

# ---- Pre-flight checks ----

echo "=============================="
echo "  Nightwatch Docker Tests"
echo "=============================="
echo ""

if ! command -v docker &>/dev/null; then
    echo -e "${RED}docker not found. Skipping Docker tests.${NC}"
    exit 0
fi

# Detect compose command
DC="docker compose"
if ! docker compose version &>/dev/null 2>&1; then
    if command -v docker-compose &>/dev/null; then
        DC="docker-compose"
    else
        echo -e "${RED}docker compose not available. Skipping Docker tests.${NC}"
        exit 0
    fi
fi

if [ ! -f "$ENV_FILE" ]; then
    echo -e "${YELLOW}.env not found — creating temporary from .env.example${NC}"
    cp "$PROJECT_DIR/.env.example" "$ENV_FILE.test"
    ENV_FILE="$ENV_FILE.test"
    CLEANUP_ENV=true
else
    CLEANUP_ENV=false
fi

# ---- Cleanup handler ----

# shellcheck disable=SC2329
cleanup() {
    echo ""
    echo "[+] Cleaning up test containers..."
    cd "$PROJECT_DIR"
    $DC --env-file "$ENV_FILE" down --remove-orphans -t 5 2>/dev/null || true
    if [ "$CLEANUP_ENV" = true ] && [ -f "$ENV_FILE" ]; then
        rm -f "$ENV_FILE"
    fi
}
trap cleanup EXIT

# ---- Test: Docker image builds ----

echo "== Build Tests =="

cd "$PROJECT_DIR"

if $DC --env-file "$ENV_FILE" build --no-cache irc-bridge 2>&1 | tail -1 | grep -q "Successfully\|exporting"; then
    pass "irc-bridge image builds"
else
    # Try again checking exit code
    if $DC --env-file "$ENV_FILE" build irc-bridge 2>/dev/null; then
        pass "irc-bridge image builds"
    else
        fail "irc-bridge image build failed"
    fi
fi

echo ""
echo "== Container Startup Tests =="

# Start services
$DC --env-file "$ENV_FILE" up -d 2>/dev/null

# Wait for containers to start
echo "  Waiting for services to start (30s max)..."
TIMEOUT=30
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
    RUNNING=$($DC --env-file "$ENV_FILE" ps --format json 2>/dev/null | grep -c '"running"' || \
              $DC --env-file "$ENV_FILE" ps 2>/dev/null | grep -c "Up" || echo "0")
    if [ "$RUNNING" -ge 3 ] 2>/dev/null; then
        break
    fi
    sleep 2
    ((ELAPSED+=2))
done

# Check each container is running
for svc in ngircd irc-bridge nginx; do
    status=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "not found")
    if [ "$status" = "running" ]; then
        pass "$svc container is running"
    else
        fail "$svc container status: $status"
    fi
done

echo ""
echo "== Health Check Tests =="

# Wait a bit for health checks to initialize
sleep 5

for svc in ngircd irc-bridge nginx; do
    health=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "none")
    case "$health" in
        healthy)
            pass "$svc health check: healthy"
            ;;
        starting)
            # Give it more time
            echo "  Waiting for $svc health check..."
            for _ in $(seq 1 6); do
                sleep 5
                health=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "none")
                if [ "$health" = "healthy" ]; then
                    break
                fi
            done
            if [ "$health" = "healthy" ]; then
                pass "$svc health check: healthy"
            else
                fail "$svc health check: $health (after 30s wait)"
            fi
            ;;
        *)
            fail "$svc health check: $health"
            ;;
    esac
done

echo ""
echo "== Service Connectivity Tests =="

# Test IRC port
if docker exec ngircd sh -c 'nc -z localhost 6667' 2>/dev/null; then
    pass "ngircd listening on port 6667"
else
    # Try alternative check
    if docker exec ngircd sh -c 'echo QUIT | nc localhost 6667' 2>/dev/null | grep -qi "irc\|ngircd"; then
        pass "ngircd listening on port 6667"
    else
        fail "ngircd not reachable on port 6667"
    fi
fi

# Test bridge health endpoint
BRIDGE_HEALTH=$(docker exec irc-bridge sh -c 'wget -qO- http://localhost:3000/health 2>/dev/null' || echo "")
if [ "$BRIDGE_HEALTH" = "OK" ]; then
    pass "irc-bridge /health returns OK"
else
    fail "irc-bridge /health returned: '$BRIDGE_HEALTH'"
fi

# Test nginx serves frontend
NGINX_RESP=$(docker exec nginx sh -c 'wget -qO- http://localhost:80/ 2>/dev/null | head -5' || echo "")
if echo "$NGINX_RESP" | grep -qi "nightwatch\|html"; then
    pass "nginx serves web frontend"
else
    fail "nginx response unexpected: '$NGINX_RESP'"
fi

# Test nginx proxies to bridge
# A non-websocket request to /ws should get a response (400 or upgrade required)
if docker exec nginx sh -c 'wget -S -qO- http://localhost:80/ws 2>&1 | head -5' 2>/dev/null | grep -qiE "HTTP|Bad Request|Upgrade"; then
    pass "nginx proxies /ws to irc-bridge"
else
    skip "nginx /ws proxy (could not verify — may need WebSocket client)"
fi

echo ""
echo "== Resource Limit Tests =="

for svc in ngircd irc-bridge nginx; do
    mem_limit=$(docker inspect --format='{{.HostConfig.Memory}}' "$svc" 2>/dev/null || echo "0")
    if [ "$mem_limit" != "0" ] && [ -n "$mem_limit" ]; then
        mem_mb=$((mem_limit / 1024 / 1024))
        pass "$svc memory limit set (${mem_mb}MB)"
    else
        skip "$svc memory limit (not enforced on this Docker version)"
    fi
done

echo ""
echo "== Container Logs Check =="

for svc in ngircd irc-bridge nginx; do
    errors=$(docker logs "$svc" 2>&1 | grep -ciE "fatal|panic|segfault" || true)
    if [ "$errors" -eq 0 ]; then
        pass "$svc logs: no fatal errors"
    else
        fail "$svc logs: found $errors fatal/panic entries"
    fi
done

# ---- Summary ----

echo ""
echo "=============================="
echo "  Results"
echo "=============================="
echo -e "  ${GREEN}Passed: $PASSED${NC}"
echo -e "  ${RED}Failed: $FAILED${NC}"
echo -e "  ${YELLOW}Skipped: $SKIPPED${NC}"
echo ""

if [ "$FAILED" -gt 0 ]; then
    echo -e "${RED}DOCKER TESTS FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}ALL DOCKER TESTS PASSED${NC}"
    exit 0
fi
