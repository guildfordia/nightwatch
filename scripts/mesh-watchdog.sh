#!/bin/bash
# Nightwatch — Mesh Watchdog
#
# Checks that wlan1 is in mesh mode and batman-adv is functional.
# If the ath9k_htc firmware has reset (dropping wlan1 back to managed mode),
# restarts the mesh service to recover.
#
# Run by systemd timer every 30 seconds.

set -euo pipefail

LOG_TAG="nightwatch-watchdog"
log() { logger -t "$LOG_TAG" "$1" 2>/dev/null || true; }

# Read config
if [ -f /etc/nightwatch.conf ]; then
    # shellcheck source=/dev/null
    source /etc/nightwatch.conf
fi
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-/opt/nightwatch}"

MESH_IFACE="wlan1"
# Read from .env (actual config), fall back to .env.example (template)
if [ -f "$NIGHTWATCH_DIR/.env" ]; then
    MESH_IFACE=$(grep '^MESH_IFACE=' "$NIGHTWATCH_DIR/.env" | cut -d= -f2 || echo "wlan1")
elif [ -f "$NIGHTWATCH_DIR/.env.example" ]; then
    MESH_IFACE=$(grep '^MESH_IFACE=' "$NIGHTWATCH_DIR/.env.example" | cut -d= -f2 || echo "wlan1")
fi

# Check if mesh service is supposed to be running
if ! systemctl is-active --quiet nightwatch-mesh 2>/dev/null; then
    # Mesh service isn't active — nothing to watch
    exit 0
fi

# Check if wlan1 exists
if [ ! -d "/sys/class/net/$MESH_IFACE" ]; then
    log "$MESH_IFACE missing — dongle may have disconnected, attempting USB reset"
    # Find the device by vendor:product ID since the net/ subdirectory
    # disappears when the ath9k_htc driver crashes
    for dev in /sys/bus/usb/devices/*/idVendor; do
        USB_DEV=$(dirname "$dev")
        if [ "$(cat "$USB_DEV/idVendor" 2>/dev/null)" = "0cf3" ] && \
           [ "$(cat "$USB_DEV/idProduct" 2>/dev/null)" = "9271" ]; then
            log "Found AR9271 at $USB_DEV — resetting"
            echo 0 > "$USB_DEV/authorized" 2>/dev/null || true
            sleep 2
            echo 1 > "$USB_DEV/authorized" 2>/dev/null || true
            sleep 5
            break
        fi
    done
    if [ -d "/sys/class/net/$MESH_IFACE" ]; then
        log "$MESH_IFACE recovered after USB reset — restarting mesh"
        systemctl restart nightwatch-mesh
    else
        log "$MESH_IFACE still missing after USB reset"
    fi
    exit 0
fi

# Check if wlan1 is in mesh mode
IFACE_TYPE=$(iw dev "$MESH_IFACE" info 2>/dev/null | grep -oP 'type \K\S+' || true)

if [ "$IFACE_TYPE" != "mesh" ]; then
    log "$MESH_IFACE is in '$IFACE_TYPE' mode (expected mesh) — restarting mesh service"
    systemctl restart nightwatch-mesh
    exit 0
fi

# Check if wlan1 is registered in batman-adv (try new syntax, fall back to old)
if ! batctl meshif bat0 if 2>/dev/null | grep -q "$MESH_IFACE" && \
   ! batctl if 2>/dev/null | grep -q "$MESH_IFACE"; then
    log "$MESH_IFACE not in batman-adv — restarting mesh service"
    systemctl restart nightwatch-mesh
    exit 0
fi
