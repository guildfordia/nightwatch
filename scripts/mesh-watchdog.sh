#!/bin/bash
# Nightwatch — Mesh Watchdog
#
# Checks that wlan1 is in mesh mode, hostapd is running, and batman-adv
# is functional. Recovers from ath9k_htc firmware crashes, interface swaps
# after driver reload, and hostapd failures.
#
# Recovery strategy (escalating):
#   1. Restart mesh service (fixes most issues)
#   2. USB device reset (fixes firmware crashes)
#   3. Reboot (fixes interface swaps after driver reload)
#
# Run by systemd timer every 30 seconds.

set -euo pipefail
export PATH="/usr/sbin:/sbin:$PATH"

LOG_TAG="nightwatch-watchdog"
log() { logger -t "$LOG_TAG" "$1" 2>/dev/null || true; }

FAIL_COUNT_FILE="/run/nightwatch-watchdog-fails"

# Read config
if [ -f /etc/nightwatch.conf ]; then
    # shellcheck source=/dev/null
    source /etc/nightwatch.conf
fi
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-/opt/nightwatch}"

MESH_IFACE="wlan1"
AP_IFACE="wlan2"
if [ -f "$NIGHTWATCH_DIR/.env" ]; then
    MESH_IFACE=$(grep '^MESH_IFACE=' "$NIGHTWATCH_DIR/.env" | cut -d= -f2 || echo "wlan1")
    AP_IFACE=$(grep '^AP_IFACE=' "$NIGHTWATCH_DIR/.env" | cut -d= -f2 || echo "wlan2")
elif [ -f "$NIGHTWATCH_DIR/.env.example" ]; then
    MESH_IFACE=$(grep '^MESH_IFACE=' "$NIGHTWATCH_DIR/.env.example" | cut -d= -f2 || echo "wlan1")
    AP_IFACE=$(grep '^AP_IFACE=' "$NIGHTWATCH_DIR/.env.example" | cut -d= -f2 || echo "wlan2")
fi

# Only run if mesh service is enabled (not disabled by operator)
if ! systemctl is-enabled --quiet nightwatch-mesh 2>/dev/null; then
    exit 0
fi

# Track consecutive failures for escalation
get_fail_count() { cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0; }
set_fail_count() { echo "$1" > "$FAIL_COUNT_FILE" 2>/dev/null || true; }
clear_fails() { rm -f "$FAIL_COUNT_FILE" 2>/dev/null || true; }

HEALTHY=true

# If mesh is in "failed" or "inactive" state, treat as unhealthy immediately
MESH_STATE=$(systemctl is-active nightwatch-mesh 2>/dev/null || echo "unknown")
if [ "$MESH_STATE" = "failed" ] || [ "$MESH_STATE" = "inactive" ]; then
    log "nightwatch-mesh is $MESH_STATE — triggering recovery"
    HEALTHY=false
fi

# ---- Check 1: mesh interface exists and is in mesh mode ----

if [ "$HEALTHY" = true ] && [ ! -d "/sys/class/net/$MESH_IFACE" ]; then
    log "$MESH_IFACE missing — dongle may have crashed"
    HEALTHY=false
elif [ "$HEALTHY" = true ]; then
    IFACE_TYPE=$(iw dev "$MESH_IFACE" info 2>/dev/null | grep -oP 'type \K\S+' || true)
    if [ "$IFACE_TYPE" != "mesh" ]; then
        log "$MESH_IFACE is '$IFACE_TYPE' (expected mesh)"
        HEALTHY=false
    fi
fi

# ---- Check 2: mesh interface is in batman-adv ----

if [ "$HEALTHY" = true ]; then
    if ! batctl meshif bat0 if 2>/dev/null | grep -q "$MESH_IFACE" && \
       ! batctl if 2>/dev/null | grep -q "$MESH_IFACE"; then
        log "$MESH_IFACE not in batman-adv"
        HEALTHY=false
    fi
fi

# ---- Check 3: hostapd is running ----

HOSTAPD_PID="/var/run/hostapd-nightwatch.pid"
if [ "$HEALTHY" = true ]; then
    if [ ! -f "$HOSTAPD_PID" ] || ! kill -0 "$(cat "$HOSTAPD_PID" 2>/dev/null)" 2>/dev/null; then
        log "hostapd not running"
        HEALTHY=false
    fi
fi

# ---- Check 4: AP interface exists ----

if [ "$HEALTHY" = true ] && [ ! -d "/sys/class/net/$AP_IFACE" ]; then
    log "$AP_IFACE missing"
    HEALTHY=false
fi

# ---- Check 5: dnsmasq is running (CdC §3.4 #3a) ----
# dnsmasq is launched inline by mesh-fix.sh and has no systemd unit of its
# own, so without this check a `kill` would leave clients without DHCP/DNS.

DNSMASQ_PID="/var/run/dnsmasq-nightwatch.pid"
if [ "$HEALTHY" = true ]; then
    if [ ! -f "$DNSMASQ_PID" ] || ! kill -0 "$(cat "$DNSMASQ_PID" 2>/dev/null)" 2>/dev/null; then
        log "dnsmasq not running — restarting (the rest of the mesh is healthy)"
        "$NIGHTWATCH_DIR/scripts/mesh-fix.sh" restart-dnsmasq 2>&1 | logger -t "$LOG_TAG" || true
        # No mesh-level escalation: dnsmasq death doesn't reset the failure
        # counter for hostapd/mesh, and a successful restart leaves us healthy.
        if [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID" 2>/dev/null)" 2>/dev/null; then
            log "dnsmasq restarted successfully"
            clear_fails
            exit 0
        fi
        HEALTHY=false
    fi
fi

# ---- All healthy — reset failure counter ----

if [ "$HEALTHY" = true ]; then
    clear_fails
    exit 0
fi

# ---- Recovery (escalating) ----

FAILS=$(get_fail_count)
FAILS=$((FAILS + 1))
set_fail_count "$FAILS"

if [ "$FAILS" -le 2 ]; then
    # Level 1: Restart mesh service
    log "Recovery attempt $FAILS/6: restarting mesh service"
    systemctl restart nightwatch-mesh 2>/dev/null || true
    # Give mesh time to start, then check if it recovered
    sleep 10
    if systemctl is-active --quiet nightwatch-mesh 2>/dev/null; then
        log "Recovery succeeded after mesh restart"
        clear_fails
    fi

elif [ "$FAILS" -le 4 ]; then
    # Level 2: USB reset for AR9271 dongles + restart mesh
    log "Recovery attempt $FAILS/6: USB reset + mesh restart"
    for dev in /sys/bus/usb/devices/*/idVendor; do
        USB_DEV=$(dirname "$dev")
        if [ "$(cat "$USB_DEV/idVendor" 2>/dev/null)" = "0cf3" ] && \
           [ "$(cat "$USB_DEV/idProduct" 2>/dev/null)" = "9271" ]; then
            log "Resetting AR9271 at $USB_DEV"
            echo 0 > "$USB_DEV/authorized" 2>/dev/null || true
            sleep 2
            echo 1 > "$USB_DEV/authorized" 2>/dev/null || true
        fi
    done
    sleep 5
    systemctl restart nightwatch-mesh 2>/dev/null || true
    # Give mesh time to start, then check if it recovered
    sleep 10
    if systemctl is-active --quiet nightwatch-mesh 2>/dev/null; then
        log "Recovery succeeded after USB reset"
        clear_fails
    fi

elif [ "$FAILS" -le 6 ]; then
    # Level 3: Reboot (fixes interface swaps after driver reload)
    log "Recovery attempt $FAILS/6: rebooting (interface may be swapped)"
    clear_fails
    reboot
fi
