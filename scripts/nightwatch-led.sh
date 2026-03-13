#!/bin/bash
# Nightwatch — LED readiness indicator
#
# Uses the Raspberry Pi's onboard green ACT LED to show node status:
#   - Heartbeat (slow blink) = booting / services starting
#   - Fast blink             = error / critical service down
#   - Solid green            = all services up and ready
#   - Default (mmc0)         = restored on stop (normal disk activity LED)
#
# The script runs as a long-lived service, periodically checking health
# and updating the LED pattern accordingly.
#
# Usage:
#   nightwatch-led.sh start    # begin LED status monitoring
#   nightwatch-led.sh stop     # restore default LED behavior
#   nightwatch-led.sh status   # print current readiness and exit

set -euo pipefail

# ---- LED control ----

# Find the green ACT LED — it's "ACT" on most Pis, "led0" on older ones
LED_PATH=""
for candidate in /sys/class/leds/ACT /sys/class/leds/led0; do
    if [ -d "$candidate" ]; then
        LED_PATH="$candidate"
        break
    fi
done

if [ -z "$LED_PATH" ]; then
    echo "[!] No onboard LED found — exiting"
    exit 0
fi

led_set_trigger() {
    local trigger="$1"
    echo "$trigger" > "$LED_PATH/trigger" 2>/dev/null || true
}

led_set_brightness() {
    local val="$1"
    # Must set trigger to "none" first for manual control
    led_set_trigger "none"
    echo "$val" > "$LED_PATH/brightness" 2>/dev/null || true
}

led_heartbeat() {
    led_set_trigger "heartbeat"
}

led_fast_blink() {
    led_set_trigger "timer"
    echo 100 > "$LED_PATH/delay_on" 2>/dev/null || true
    echo 100 > "$LED_PATH/delay_off" 2>/dev/null || true
}

led_solid_on() {
    led_set_trigger "none"
    echo 1 > "$LED_PATH/brightness" 2>/dev/null || true
}

led_restore_default() {
    # Restore the default trigger (disk activity)
    led_set_trigger "mmc0"
}

# ---- Health checks ----

check_ready() {
    # Returns 0 if all critical services are up, 1 if something is wrong,
    # 2 if services are still starting up
    #
    # Logic: any_failed=true means at least one service is definitively down.
    #        any_starting=true means at least one is still activating.
    #        If nothing is failed and nothing is starting, everything is up.

    local any_failed=false
    local any_starting=false

    # Check a systemd service: active=ok, activating=starting, else=failed
    check_svc() {
        local svc="$1"
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            return  # up
        fi
        if ! systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            return  # not enabled, don't count
        fi
        local state
        state=$(systemctl show -p ActiveState --value "$svc" 2>/dev/null || echo "unknown")
        if [ "$state" = "activating" ]; then
            any_starting=true
        else
            any_failed=true
        fi
    }

    check_svc nightwatch-mesh
    check_svc nightwatch-app

    # Check if bat0 interface exists (mesh is actually functional)
    if [ ! -d /sys/class/net/bat0 ]; then
        # Only count as failed if mesh service isn't still starting
        if [ "$any_starting" = false ]; then
            any_failed=true
        fi
    fi

    # Check if br0 bridge has an IP
    if ! ip -4 addr show dev br0 2>/dev/null | grep -q inet; then
        if [ "$any_starting" = false ]; then
            any_failed=true
        fi
    fi

    if [ "$any_failed" = true ]; then
        return 1  # error — at least one service/interface is down
    elif [ "$any_starting" = true ]; then
        return 2  # starting — nothing failed, some still coming up
    else
        return 0  # ready — everything is up
    fi
}

print_status() {
    local rc=0
    check_ready || rc=$?

    case "$rc" in
        0) echo "READY — all services up" ;;
        1) echo "ERROR — one or more services down" ;;
        2) echo "STARTING — services are coming up" ;;
    esac

    echo ""
    echo "Services:"
    for svc in nightwatch-mesh nightwatch-app nightwatch-discovery; do
        local state
        state=$(systemctl show -p ActiveState --value "$svc" 2>/dev/null || echo "unknown")
        printf "  %-30s %s\n" "$svc" "$state"
    done

    echo ""
    echo "Interfaces:"
    for iface in bat0 br0; do
        if [ -d "/sys/class/net/$iface" ]; then
            local ip
            ip=$(ip -4 addr show dev "$iface" 2>/dev/null | grep -oP 'inet \K[^ ]+' || echo "no IP")
            printf "  %-10s UP (%s)\n" "$iface" "$ip"
        else
            printf "  %-10s DOWN\n" "$iface"
        fi
    done

    echo ""
    echo "LED: $LED_PATH (trigger: $(cat "$LED_PATH/trigger" 2>/dev/null | grep -oP '\[\K[^\]]+' || echo 'unknown'))"
}

# ---- Main ----

case "${1:-}" in
    start)
        echo "[+] Nightwatch LED status indicator starting"
        echo "[+] LED: $LED_PATH"

        # Start with heartbeat (booting)
        led_heartbeat

        # Loop forever, checking health every 10 seconds
        while true; do
            rc=0
            check_ready || rc=$?

            case "$rc" in
                0)
                    led_solid_on
                    ;;
                1)
                    led_fast_blink
                    ;;
                2)
                    led_heartbeat
                    ;;
            esac

            sleep 10
        done
        ;;

    stop)
        echo "[+] Restoring default LED behavior"
        led_restore_default
        ;;

    status)
        print_status
        ;;

    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
