#!/bin/bash
# Nightwatch — Advanced Mesh Network Scan
#
# Deep per-node probe of every slot in the mesh (192.168.199.101–120):
#
#   Phase 1 — Fast fping sweep to find live nodes
#   Phase 2 — Parallel deep probe for each live node:
#               • Ping: min/avg/max RTT, packet loss
#               • Ports: IRC 6667, HTTP 80
#               • IRC protocol: LINKS (federation count), LUSERS (user count)
#               • HTTP: nginx frontend (HTTP code), bridge /ws (health)
#   Phase 3 — Local batman-adv topology (this node only, needs root)
#   Phase 4 — Per-node report cards
#   Phase 5 — Summary table (all 20 slots)
#
# Usage:
#   sudo ./scripts/test-scan.sh [--quick] [--node N]
#   --quick    Skip IRC protocol probes (faster, connectivity check only)
#   --node N   Show full report card only for node N (probes all nodes)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── Argument parsing ────────────────────────────────────────────────────────
QUICK_MODE=false
TARGET_NODE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick) QUICK_MODE=true ;;
        --node)  shift; TARGET_NODE="${1:-}" ;;
        *)       ;;
    esac
    shift
done

# ── Load config ─────────────────────────────────────────────────────────────
load_env "$ENV_FILE"

BAT_IFACE="${BAT_IFACE:-bat0}"
BR_IFACE="${BR_IFACE:-br0}"
MESH_IFACE="${MESH_IFACE:-wlan1}"
IRC_PORT="${IRC_PORT:-6667}"
NGINX_PORT="${NGINX_PORT:-80}"
LOCAL_IP="${MESH_IP%/*}"

# Prefer br0 for scanning (has the mesh IP); fall back to bat0
SCAN_IFACE="$BR_IFACE"
[ ! -d "/sys/class/net/$BR_IFACE" ] && SCAN_IFACE="$BAT_IFACE"

# ── Temp directory ──────────────────────────────────────────────────────────
SCAN_TMP=$(mktemp -d /tmp/nightwatch-scan.XXXXX)
SCAN_START=$(date +%s)
trap 'rm -rf "$SCAN_TMP"' EXIT

# ── Portable millisecond clock ───────────────────────────────────────────────
# date +%s%3N is GNU-only; macOS date doesn't support %N.
_now_ms() { date +%s%3N 2>/dev/null | grep -qE '^[0-9]{13}$' \
    && date +%s%3N || echo $(( $(date +%s) * 1000 )); }

# ── dat helpers ─────────────────────────────────────────────────────────────
# Safe key=value reader — avoids variable contamination between iterations
dat_get() { grep "^${2}=" "$1" 2>/dev/null | cut -d= -f2-; }

# ── Probe function ──────────────────────────────────────────────────────────
# probe_node <node_num> <ip>
# Writes probe results to $SCAN_TMP/node<N>.dat as KEY=VALUE pairs.
probe_node() {
    # Prevent the background subshell from firing the parent's EXIT trap,
    # which would delete SCAN_TMP before other probes finish writing.
    trap '' EXIT

    local node_num="$1"
    local ip="$2"
    local dat="$SCAN_TMP/node${node_num}.dat"
    local t0; t0=$(_now_ms)

    # ── Ping (5 packets, 2 s timeout) ──
    local reachable=0 rtt_min="" rtt_avg="" rtt_max="" rtt_mdev="" loss=100
    # Skip network ping for the local node — it's always up
    if [ "$ip" = "$LOCAL_IP" ]; then
        reachable=1; rtt_min="-"; rtt_avg="-"; rtt_max="-"; rtt_mdev="-"; loss=0
    else
        local ping_out
        ping_out=$(ping -c 5 -W 2 -I "$SCAN_IFACE" "$ip" 2>/dev/null || true)
        local stats
        stats=$(echo "$ping_out" | grep -oP '\d+\.\d+/\d+\.\d+/\d+\.\d+/\d+\.\d+' || true)
        if [ -n "$stats" ]; then
            reachable=1
            rtt_min=$(echo "$stats" | cut -d/ -f1)
            rtt_avg=$(echo "$stats" | cut -d/ -f2)
            rtt_max=$(echo "$stats" | cut -d/ -f3)
            rtt_mdev=$(echo "$stats" | cut -d/ -f4)
            loss=$(echo "$ping_out" | grep "packet loss" | grep -oP '\d+(?=% packet loss)' || echo "100")
        fi
    fi

    # ── Port checks ──
    local irc_open=0 http_open=0
    nc -z -w 3 "$ip" "$IRC_PORT"   2>/dev/null && irc_open=1  || true
    nc -z -w 3 "$ip" "$NGINX_PORT" 2>/dev/null && http_open=1 || true

    # ── HTTP probes ──
    local http_code="000" ws_code="000"
    if [ "$http_open" = "1" ]; then
        http_code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
            "http://${ip}:${NGINX_PORT}/"   2>/dev/null || echo "000")
        ws_code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" \
            "http://${ip}:${NGINX_PORT}/ws" 2>/dev/null || echo "000")
    fi
    # Bridge alive: /ws returns 400 (bad request), 426 (upgrade required), or 101 (upgraded)
    local bridge_ok=0
    case "$ws_code" in 400|426|101) bridge_ok=1 ;; esac

    # ── IRC protocol probe (LINKS + LUSERS + VERSION) ──
    local irc_servers=0 irc_users=0 irc_version="" irc_server_list=""
    if [ "$irc_open" = "1" ] && [ "$QUICK_MODE" = "false" ]; then
        local nick; nick="sc${node_num}$(( $$ % 9999 ))"
        nick="${nick:0:12}"  # ngircd MaxNickLength = 12

        local irc_raw
        irc_raw=$(
            {
                printf "NICK %s\r\n" "$nick"
                printf "USER sc 0 * :NW-Scanner\r\n"
                sleep 3
                printf "LINKS\r\n"
                printf "LUSERS\r\n"
                printf "VERSION\r\n"
                sleep 3
                printf "QUIT :scan\r\n"
            } | timeout 12 nc -w 14 "$ip" "$IRC_PORT" 2>/dev/null || true
        )

        # 364 = RPL_LINKS (one per server in network, including self)
        irc_servers=$(echo "$irc_raw" | grep -c " 364 " || true)
        irc_server_list=$(echo "$irc_raw" | grep " 364 " | awk '{print $4}' \
            | tr '\n' ',' | sed 's/,$//' || true)

        # 255 = RPL_LUSERME: "I have N clients and M servers"
        local lusers_me
        lusers_me=$(echo "$irc_raw" | grep " 255 " | head -1 || true)
        irc_users=$(echo "$lusers_me" | grep -oP 'I have \K\d+' || echo "0")

        # 351 = RPL_VERSION
        irc_version=$(echo "$irc_raw" | grep " 351 " | awk '{print $4}' | head -1 || true)
    fi

    local t1; t1=$(_now_ms)

    # ── Write results ──
    cat > "$dat" <<EOF
REACHABLE=$reachable
RTT_MIN=$rtt_min
RTT_AVG=$rtt_avg
RTT_MAX=$rtt_max
RTT_MDEV=$rtt_mdev
LOSS=$loss
IRC_OPEN=$irc_open
HTTP_OPEN=$http_open
HTTP_CODE=$http_code
WS_CODE=$ws_code
BRIDGE_OK=$bridge_ok
IRC_SERVERS=$irc_servers
IRC_USERS=$irc_users
IRC_VERSION=$irc_version
IRC_SERVER_LIST=$irc_server_list
DURATION_MS=$(( t1 - t0 ))
EOF
    return 0
}

# ── Offline node stub ───────────────────────────────────────────────────────
write_offline_dat() {
    cat > "$SCAN_TMP/node${1}.dat" <<'EOF'
REACHABLE=0
RTT_MIN=
RTT_AVG=
RTT_MAX=
RTT_MDEV=
LOSS=100
IRC_OPEN=0
HTTP_OPEN=0
HTTP_CODE=000
WS_CODE=000
BRIDGE_OK=0
IRC_SERVERS=0
IRC_USERS=0
IRC_VERSION=
IRC_SERVER_LIST=
DURATION_MS=0
EOF
}

# ════════════════════════════════════════════════════════════════════════════
# Header
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Nightwatch  Advanced  Mesh  Scan         ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Date:       $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "  This node:  $LOCAL_IP  (node #${PI_NUMBER:-?})"
echo -e "  Interface:  $SCAN_IFACE"
echo -e "  Mode:       $([ "$QUICK_MODE" = "true" ] && echo "quick  (IRC probes skipped)" || echo "full  (ping + ports + IRC + HTTP)")"
[ -n "$TARGET_NODE" ] && echo -e "  Focus:      node $TARGET_NODE only"
echo ""

# ════════════════════════════════════════════════════════════════════════════
# Phase 1 — Network sweep
# ════════════════════════════════════════════════════════════════════════════

echo -e "${BOLD}${CYAN}━━━  Phase 1: Network Sweep  ━━━${NC}"
echo ""

declare -a LIVE_NODES=() LIVE_IPS=() OFFLINE_NODES=()
declare -a ALL_IPS=()
for i in $(seq 1 "$MAX_NODES"); do ALL_IPS+=("$(mesh_ip_for_node "$i")"); done

t_sweep0=$(_now_ms)

# Determine which IPs respond to ping (excluding local node — always alive)
declare -a FPING_LIVE=()
if command -v fping >/dev/null 2>&1; then
    FPING_LIVE=()
    while IFS= read -r _fp_line; do
        [ -n "$_fp_line" ] && FPING_LIVE+=("$_fp_line")
    done < <(
        printf '%s\n' "${ALL_IPS[@]}" \
        | timeout 15 fping -a -r 1 -t 1000 -I "$SCAN_IFACE" 2>/dev/null || true
    )
else
    for ip in "${ALL_IPS[@]}"; do
        [ "$ip" = "$LOCAL_IP" ] && continue
        ping -c 1 -W 1 -I "$SCAN_IFACE" "$ip" >/dev/null 2>&1 && FPING_LIVE+=("$ip") || true
    done
fi

t_sweep1=$(_now_ms)

# Build live / offline lists (always include local node in live)
for i in $(seq 1 "$MAX_NODES"); do
    ip="$(mesh_ip_for_node "$i")"
    if [ "$ip" = "$LOCAL_IP" ]; then
        LIVE_NODES+=("$i"); LIVE_IPS+=("$ip")
    elif [ ${#FPING_LIVE[@]} -gt 0 ] && printf '%s\n' "${FPING_LIVE[@]}" | grep -qx "$ip"; then
        LIVE_NODES+=("$i"); LIVE_IPS+=("$ip")
    else
        OFFLINE_NODES+=("$i")
    fi
done

echo -e "  ${GREEN}${#LIVE_NODES[@]} node(s) online${NC}  ${DIM}·  $((MAX_NODES - ${#LIVE_NODES[@]})) offline  ·  sweep: $(( t_sweep1 - t_sweep0 ))ms${NC}"
echo ""

for i in "${!LIVE_NODES[@]}"; do
    n="${LIVE_NODES[$i]}"; ip="${LIVE_IPS[$i]}"
    [ "$ip" = "$LOCAL_IP" ] \
        && echo -e "  ${GREEN}●${NC}  node${n}   ${ip}   ${DIM}(this node)${NC}" \
        || echo -e "  ${GREEN}●${NC}  node${n}   ${ip}"
done
[ ${#OFFLINE_NODES[@]} -gt 0 ] && for n in "${OFFLINE_NODES[@]}"; do
    echo -e "  ${DIM}○  node${n}   $(mesh_ip_for_node "$n")   offline${NC}"
done || true

# ════════════════════════════════════════════════════════════════════════════
# Phase 2 — Parallel deep probes
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}${CYAN}━━━  Phase 2: Deep Probe (parallel)  ━━━${NC}"
echo ""

if [ "${#LIVE_NODES[@]}" -eq 0 ]; then
    echo -e "  ${YELLOW}No live nodes to probe.${NC}"
else
    echo "  Probing ${#LIVE_NODES[@]} node(s) in parallel..."
    declare -a PROBE_PIDS=()
    for i in "${!LIVE_NODES[@]}"; do
        probe_node "${LIVE_NODES[$i]}" "${LIVE_IPS[$i]}" &
        PROBE_PIDS+=($!)
    done
    for pid in "${PROBE_PIDS[@]}"; do wait "$pid" 2>/dev/null || true; done
    echo -e "  ${GREEN}Done.${NC}"
fi

[ ${#OFFLINE_NODES[@]} -gt 0 ] && for n in "${OFFLINE_NODES[@]}"; do write_offline_dat "$n"; done || true

# ════════════════════════════════════════════════════════════════════════════
# Phase 3 — Local batman-adv topology  (requires root)
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}${CYAN}━━━  Phase 3: Local batman-adv Topology  ━━━${NC}"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo -e "  ${YELLOW}⚠  Run as root (sudo) for batman-adv and 802.11s data.${NC}"
else
    # ── batman-adv neighbors ──
    bat_neigh_raw=$(batctl meshif "$BAT_IFACE" n 2>/dev/null \
                 || batctl n 2>/dev/null || true)
    mesh_neighbors=$(echo "$bat_neigh_raw" | grep "$MESH_IFACE" || true)
    neigh_count=$(echo "$mesh_neighbors" | grep -c "$MESH_IFACE" 2>/dev/null || true)
    neigh_count=$(( neigh_count + 0 ))

    echo -e "  batman-adv neighbors via $MESH_IFACE:  ${neigh_count}"
    if [ -n "$mesh_neighbors" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            mac=$(echo "$line" | awk '{print $1}')
            last=$(echo "$line" | awk '{print $2}')
            tq=$(echo "$line"  | awk '{print $3}')
            echo -e "    ${DIM}└─ $mac  TQ: ${tq}/255  last active: ${last}${NC}"
        done <<< "$mesh_neighbors"
    fi

    # ── batman-adv originators (unique routes) ──
    bat_orig=$(batctl meshif "$BAT_IFACE" o 2>/dev/null \
            || batctl o 2>/dev/null || true)
    orig_count=$(echo "$bat_orig" | grep -c "^ \*" 2>/dev/null || true)
    orig_count=$(( orig_count + 0 ))
    echo -e "  batman-adv originators:              ${orig_count}"

    # ── Gateway mode ──
    gw_mode=$(batctl meshif "$BAT_IFACE" gw_mode 2>/dev/null \
           || batctl gw_mode 2>/dev/null || echo "unknown")
    echo -e "  batman-adv gateway mode:             ${gw_mode}"

    # ── 802.11s direct peers ──
    mesh_stations=$(iw dev "$MESH_IFACE" station dump 2>/dev/null || true)
    sta_count=$(echo "$mesh_stations" | grep -c "^Station" 2>/dev/null || true)
    sta_count=$(( sta_count + 0 ))
    echo -e "  802.11s direct peers:                ${sta_count}"
    if [ "$sta_count" -gt 0 ] && [ -n "$mesh_stations" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^Station ]] || continue
            peer_mac=$(echo "$line" | awk '{print $2}')
            signal=$(echo "$mesh_stations" \
                | grep -A 20 "^Station $peer_mac" \
                | grep "signal:" | head -1 \
                | awk '{print $2}' || true)
            inactive=$(echo "$mesh_stations" \
                | grep -A 5 "^Station $peer_mac" \
                | grep "inactive time:" | awk '{print $3, $4}' || true)
            echo -e "    ${DIM}└─ $peer_mac  signal: ${signal:-?} dBm  inactive: ${inactive:-?}${NC}"
        done <<< "$mesh_stations"
    fi

    # ── Discovery daemon peer file ──
    echo ""
    PEER_FILE="/run/nightwatch-peers"
    if systemctl is-active --quiet nightwatch-discovery.service 2>/dev/null; then
        echo -e "  Discovery daemon:  ${GREEN}running${NC}"
        if [ -f "$PEER_FILE" ] && [ -s "$PEER_FILE" ]; then
            NOW=$(date +%s)
            while IFS='|' read -r pnum pip pname pts; do
                [ -z "$pnum" ] && continue
                age=$(( NOW - pts ))
                staleness=""
                [ "$age" -gt 60 ]  && staleness="  ${YELLOW}(${age}s — may be stale)${NC}"
                [ "$age" -le 60 ]  && staleness="  ${DIM}(${age}s ago)${NC}"
                echo -e "    ${DIM}└─ node${pnum}  ${pip}  ${pname}${NC}${staleness}"
            done < "$PEER_FILE"
        else
            echo -e "    ${DIM}No peers in beacon file yet${NC}"
        fi
    else
        echo -e "  Discovery daemon:  ${YELLOW}not running${NC}"
    fi
fi

# ════════════════════════════════════════════════════════════════════════════
# Phase 4 — Per-node report cards
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}${CYAN}━━━  Phase 4: Per-Node Report Cards  ━━━${NC}"

for i in $(seq 1 "$MAX_NODES"); do
    dat="$SCAN_TMP/node${i}.dat"
    [ -f "$dat" ] || continue

    ip="$(mesh_ip_for_node "$i")"

    # If --node N is set, only show the full card for that node
    if [ -n "$TARGET_NODE" ] && [ "$i" != "$TARGET_NODE" ]; then continue; fi

    REACHABLE=$(dat_get "$dat" REACHABLE)

    # Offline nodes: one-liner
    if [ "$REACHABLE" != "1" ]; then
        echo ""
        echo -e "${DIM}  ┌─ NODE ${i}   ${ip}   [OFFLINE]${NC}"
        echo -e "${DIM}  └─ Unreachable — no probe data${NC}"
        continue
    fi

    RTT_MIN=$(dat_get "$dat" RTT_MIN); RTT_AVG=$(dat_get "$dat" RTT_AVG)
    RTT_MAX=$(dat_get "$dat" RTT_MAX); RTT_MDEV=$(dat_get "$dat" RTT_MDEV)
    LOSS=$(dat_get "$dat" LOSS)
    IRC_OPEN=$(dat_get "$dat" IRC_OPEN); HTTP_OPEN=$(dat_get "$dat" HTTP_OPEN)
    HTTP_CODE=$(dat_get "$dat" HTTP_CODE); WS_CODE=$(dat_get "$dat" WS_CODE)
    BRIDGE_OK=$(dat_get "$dat" BRIDGE_OK)
    IRC_SERVERS=$(dat_get "$dat" IRC_SERVERS); IRC_USERS=$(dat_get "$dat" IRC_USERS)
    IRC_VERSION=$(dat_get "$dat" IRC_VERSION); IRC_SERVER_LIST=$(dat_get "$dat" IRC_SERVER_LIST)
    DURATION_MS=$(dat_get "$dat" DURATION_MS)

    # Header
    echo ""
    if [ "$ip" = "$LOCAL_IP" ]; then
        echo -e "${BOLD}${BLUE}  ┌─ NODE ${i}   ${ip}   [THIS NODE]${NC}"
    else
        echo -e "${BOLD}${GREEN}  ┌─ NODE ${i}   ${ip}   [ONLINE]${NC}"
    fi

    # Ping
    if [ "$ip" = "$LOCAL_IP" ]; then
        echo -e "  ${GREEN}✓${NC}  Ping:        self"
    elif [ -n "$RTT_AVG" ] && [ "$RTT_AVG" != "-" ]; then
        loss_str=""
        [ "${LOSS:-0}" -gt 0 ] && loss_str="  ${YELLOW}loss: ${LOSS}%${NC}"
        echo -e "  ${GREEN}✓${NC}  Ping:        avg ${RTT_AVG} ms   min ${RTT_MIN} / max ${RTT_MAX} / jitter ${RTT_MDEV}${loss_str}"
    else
        echo -e "  ${RED}✗${NC}  Ping:        all packets lost"
    fi

    # IRC port
    if [ "$IRC_OPEN" = "1" ]; then
        ver_str=""; [ -n "$IRC_VERSION" ] && ver_str="   (${IRC_VERSION})"
        echo -e "  ${GREEN}✓${NC}  IRC:         port ${IRC_PORT} open${ver_str}"
    else
        echo -e "  ${RED}✗${NC}  IRC:         port ${IRC_PORT} closed"
    fi

    # HTTP
    if [ "$HTTP_CODE" = "200" ]; then
        echo -e "  ${GREEN}✓${NC}  HTTP:        port ${NGINX_PORT}  HTTP ${HTTP_CODE}  (frontend OK)"
    elif [ "$HTTP_OPEN" = "1" ]; then
        echo -e "  ${YELLOW}⚠${NC}  HTTP:        port ${NGINX_PORT}  HTTP ${HTTP_CODE}"
    else
        echo -e "  ${RED}✗${NC}  HTTP:        port ${NGINX_PORT} closed"
    fi

    # Bridge /ws
    if [ "$BRIDGE_OK" = "1" ]; then
        echo -e "  ${GREEN}✓${NC}  Bridge:      /ws  HTTP ${WS_CODE}  (alive)"
    elif [ "$HTTP_OPEN" = "1" ]; then
        echo -e "  ${RED}✗${NC}  Bridge:      /ws  HTTP ${WS_CODE}  (not responding)"
    else
        echo -e "  ${DIM}—  Bridge:      (HTTP not reachable)${NC}"
    fi

    # IRC federation + users
    if [ "$QUICK_MODE" = "false" ] && [ "$IRC_OPEN" = "1" ]; then
        linked=$(( IRC_SERVERS > 0 ? IRC_SERVERS - 1 : 0 ))
        if [ "$linked" -gt 0 ]; then
            echo -e "  ${GREEN}✓${NC}  Federation:  ${linked} remote server(s) linked"
            if [ -n "$IRC_SERVER_LIST" ]; then
                echo -e "  ${DIM}             └─ ${IRC_SERVER_LIST//,/  ·  }${NC}"
            fi
        else
            echo -e "  ${YELLOW}⚠${NC}  Federation:  standalone (not linked)"
        fi
        echo -e "  ${GREEN}✓${NC}  IRC users:   ${IRC_USERS} connected client(s)"
    else
        echo -e "  ${DIM}—  Federation: (skipped in quick mode)${NC}"
    fi

    # Local extras (systemctl + hardware)
    if [ "$ip" = "$LOCAL_IP" ] && [ "$(id -u)" -eq 0 ]; then
        echo ""
        echo -e "  ${DIM}  — Local services —${NC}"
        for svc in ngircd nightwatch-bridge nginx; do
            state=$(systemctl is-active "$svc" 2>/dev/null || echo "n/a")
            if [ "$state" = "active" ]; then
                since=$(systemctl show -p ActiveEnterTimestamp --value "$svc" 2>/dev/null \
                    | cut -d' ' -f1,2 || echo "?")
                echo -e "  ${GREEN}✓${NC}  ${svc}:  active  (since ${since})"
            else
                echo -e "  ${RED}✗${NC}  ${svc}:  ${state}"
            fi
        done
        disk=$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo "?")
        load=$(cut -d' ' -f1,2,3 /proc/loadavg 2>/dev/null || echo "?")
        uptime_str=$(uptime -p 2>/dev/null || true)
        echo -e "  ${DIM}     disk: ${disk}%   load: ${load}   ${uptime_str}${NC}"
    fi

    echo -e "  ${DIM}└─ probe time: ${DURATION_MS}ms${NC}"
done

# ════════════════════════════════════════════════════════════════════════════
# Phase 5 — Summary table
# ════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}${CYAN}━━━  Phase 5: Summary Table  ━━━${NC}"
echo ""
printf "  %-4s  %-17s  %-8s  %-10s  %-5s  %-4s  %-4s  %-7s  %-5s  %-5s\n" \
    "NODE" "IP" "STATUS" "RTT (avg)" "LOSS" "IRC" "HTTP" "BRIDGE" "FED" "USERS"
printf "  %-4s  %-17s  %-8s  %-10s  %-5s  %-4s  %-4s  %-7s  %-5s  %-5s\n" \
    "────" "─────────────────" "────────" "──────────" "─────" "────" "────" "───────" "─────" "─────"

TOTAL_ONLINE=0
TOTAL_HEALTHY=0

for i in $(seq 1 "$MAX_NODES"); do
    dat="$SCAN_TMP/node${i}.dat"
    [ -f "$dat" ] || continue
    ip="$(mesh_ip_for_node "$i")"

    REACHABLE=$(dat_get "$dat" REACHABLE)
    RTT_AVG=$(dat_get "$dat" RTT_AVG)
    LOSS=$(dat_get "$dat" LOSS)
    IRC_OPEN=$(dat_get "$dat" IRC_OPEN)
    HTTP_CODE=$(dat_get "$dat" HTTP_CODE)
    BRIDGE_OK=$(dat_get "$dat" BRIDGE_OK)
    IRC_SERVERS=$(dat_get "$dat" IRC_SERVERS)
    IRC_USERS=$(dat_get "$dat" IRC_USERS)

    # Status column
    if [ "$ip" = "$LOCAL_IP" ]; then
        col_status="THIS"
        (( TOTAL_ONLINE++ )) || true
    elif [ "$REACHABLE" = "1" ]; then
        col_status="ONLINE"
        (( TOTAL_ONLINE++ )) || true
    else
        col_status="OFFLINE"
    fi

    # RTT
    if [ "$ip" = "$LOCAL_IP" ]; then
        col_rtt="self"
    elif [ -n "$RTT_AVG" ] && [ "$RTT_AVG" != "-" ]; then
        col_rtt="${RTT_AVG}ms"
    else
        col_rtt="—"
    fi

    # Loss
    col_loss="—"
    [ "$REACHABLE" = "1" ] && col_loss="${LOSS}%"
    [ "$ip" = "$LOCAL_IP" ] && col_loss="—"

    # IRC
    col_irc="—"; [ "$IRC_OPEN" = "1" ] && col_irc="OK"

    # HTTP
    col_http="—"
    [ "$HTTP_CODE" = "200" ]                         && col_http="OK"
    [ "$HTTP_CODE" != "000" ] && [ "$HTTP_CODE" != "200" ] \
        && [ "$REACHABLE" = "1" ]                    && col_http="$HTTP_CODE"

    # Bridge
    col_bridge="—"
    [ "$BRIDGE_OK" = "1" ]   && col_bridge="OK"
    [ "$REACHABLE" = "1" ] && [ "$BRIDGE_OK" = "0" ] \
        && [ "$IRC_OPEN" = "1" ] && col_bridge="FAIL"

    # Federation (servers linked = total in LINKS minus self)
    col_fed="—"
    if [ "$QUICK_MODE" = "false" ] && [ "$IRC_OPEN" = "1" ]; then
        linked=$(( IRC_SERVERS > 0 ? IRC_SERVERS - 1 : 0 ))
        col_fed="$linked"
    fi

    # Users
    col_users="—"
    [ "$QUICK_MODE" = "false" ] && [ "$IRC_OPEN" = "1" ] && col_users="$IRC_USERS"

    # Full-health check
    if [ "$REACHABLE" = "1" ] && [ "$IRC_OPEN" = "1" ] \
        && [ "$HTTP_CODE" = "200" ] && [ "$BRIDGE_OK" = "1" ]; then
        (( TOTAL_HEALTHY++ )) || true
    fi

    # Row color
    if   [ "$ip" = "$LOCAL_IP" ]; then row_color="$BLUE"
    elif [ "$REACHABLE" = "1" ];  then row_color="$GREEN"
    else                               row_color="$DIM"
    fi

    echo -e "  ${row_color}$(printf "%-4s  %-17s  %-8s  %-10s  %-5s  %-4s  %-4s  %-7s  %-5s  %-5s" \
        "$i" "$ip" "$col_status" "$col_rtt" "$col_loss" \
        "$col_irc" "$col_http" "$col_bridge" "$col_fed" "$col_users")${NC}"
done

# ── Footer ──────────────────────────────────────────────────────────────────
SCAN_END=$(date +%s)
echo ""
echo -e "  ${BOLD}Online:   ${TOTAL_ONLINE} / ${MAX_NODES} node(s)${NC}"
if [ "$QUICK_MODE" = "false" ]; then
    echo -e "  ${BOLD}Healthy:  ${TOTAL_HEALTHY} / ${TOTAL_ONLINE} online node(s) fully operational${NC}"
fi
echo -e "  ${DIM}Completed in $(( SCAN_END - SCAN_START ))s${NC}"
echo ""

if   [ "$TOTAL_ONLINE" -eq 0 ]; then
    echo -e "  ${RED}${BOLD}MESH IS DARK — no nodes reachable${NC}"
elif [ "$QUICK_MODE" = "false" ] && [ "$TOTAL_HEALTHY" -eq "$TOTAL_ONLINE" ]; then
    echo -e "  ${GREEN}${BOLD}MESH IS HEALTHY${NC}"
elif [ "$QUICK_MODE" = "false" ] && [ "$TOTAL_HEALTHY" -lt "$TOTAL_ONLINE" ]; then
    echo -e "  ${YELLOW}${BOLD}MESH HAS ISSUES — $(( TOTAL_ONLINE - TOTAL_HEALTHY )) node(s) degraded${NC}"
else
    echo -e "  ${CYAN}${BOLD}SCAN COMPLETE${NC}"
fi
echo ""
