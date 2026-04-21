#!/bin/bash
export PATH="/usr/sbin:/sbin:$PATH"
# Nightwatch — LED readiness indicator
#
# Uses the Raspberry Pi's onboard green ACT LED to show node status:
#   - Heartbeat (slow blink) = booting / services starting
#   - Fast blink             = error / critical service down
#   - Long-short (dash-dot)   = WiFi dongle crashed (needs physical replug)
#   - Triple blink (SOS)     = undervoltage detected (power too low)
#   - Slow blink (2s on/off) = all services up and ready
#   - Default (mmc0)         = restored on stop (normal disk activity LED)
#
# Undervoltage takes priority over all other states — if the Pi reports
# low voltage via vcgencmd, the LED will triple-blink regardless of
# service health. This warns that the power source (battery/USB) is
# insufficient and the Pi may crash or corrupt the SD card.
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

led_heartbeat() {
    # Manual heartbeat — no kernel trigger
    led_set_trigger "none"
}

led_heartbeat_cycle() {
    # Smooth fade-like pattern: short on, longer off (like breathing)
    echo 1 > "$LED_PATH/brightness" 2>/dev/null || true
    sleep 0.3
    echo 0 > "$LED_PATH/brightness" 2>/dev/null || true
    sleep 0.7
}

led_fast_blink() {
    # Manual fast blink — no kernel triggers (they get stuck between state changes)
    led_set_trigger "none"
    echo 1 > "$LED_PATH/brightness" 2>/dev/null || true
}

led_fast_blink_cycle() {
    # One cycle of fast blink (call in loop instead of sleep 10)
    echo 1 > "$LED_PATH/brightness" 2>/dev/null || true
    sleep 0.1
    echo 0 > "$LED_PATH/brightness" 2>/dev/null || true
    sleep 0.1
}

led_ready() {
    # Manual slow blink — no kernel triggers
    led_set_trigger "none"
    echo 1 > "$LED_PATH/brightness" 2>/dev/null || true
}

led_ready_cycle() {
    # One cycle of slow blink (call in loop instead of sleep 10)
    echo 1 > "$LED_PATH/brightness" 2>/dev/null || true
    sleep 1
    echo 0 > "$LED_PATH/brightness" 2>/dev/null || true
    sleep 1
}

led_restore_default() {
    # Restore the default trigger (disk activity)
    led_set_trigger "mmc0"
}

# Long-short blink: one long flash + one short flash, then pause.
# Used as WiFi dongle crash warning — visually distinct from all other patterns:
#   heartbeat = smooth fade (kernel), fast = rapid strobe, slow = 2s on/off,
#   triple = 3 quick flashes (undervoltage), long-short = dash-dot (WiFi crash)
# Signals: "come unplug/replug the USB WiFi dongle."
led_wifi_crash_blink() {
    led_set_trigger "none"
    # Long flash (dash)
    echo 1 > "$LED_PATH/brightness" 2>/dev/null || true
    sleep 0.5
    echo 0 > "$LED_PATH/brightness" 2>/dev/null || true
    sleep 0.2
    # Short flash (dot)
    echo 1 > "$LED_PATH/brightness" 2>/dev/null || true
    sleep 0.1
    echo 0 > "$LED_PATH/brightness" 2>/dev/null || true
    # Pause between bursts
    sleep 1.0
}

# Triple blink: 3 quick flashes then a pause (manual, runs in foreground).
# Used as undervoltage warning — visually distinct from heartbeat or fast blink.
# This is called in the main loop instead of setting a trigger, because the
# "timer" trigger can't do grouped blinks.
led_triple_blink() {
    led_set_trigger "none"
    for _ in 1 2 3; do
        echo 1 > "$LED_PATH/brightness" 2>/dev/null || true
        sleep 0.1
        echo 0 > "$LED_PATH/brightness" 2>/dev/null || true
        sleep 0.1
    done
    # Pause between bursts (caller sleeps too, so total off-time ≈ 1s)
    sleep 0.7
}

# ---- PWR LED (red, Pi 5 / some Pi 4) ----

PWR_LED_PATH=""
for candidate in /sys/class/leds/PWR /sys/class/leds/led1; do
    if [ -d "$candidate" ]; then
        PWR_LED_PATH="$candidate"
        break
    fi
done

pwr_led_set() {
    # Set PWR LED: "on" = solid, "off" = off, "blink" = timer
    [ -z "$PWR_LED_PATH" ] && return
    case "$1" in
        on)
            echo "none" > "$PWR_LED_PATH/trigger" 2>/dev/null || true
            echo 1 > "$PWR_LED_PATH/brightness" 2>/dev/null || true
            ;;
        off)
            echo "none" > "$PWR_LED_PATH/trigger" 2>/dev/null || true
            echo 0 > "$PWR_LED_PATH/brightness" 2>/dev/null || true
            ;;
        blink)
            echo "timer" > "$PWR_LED_PATH/trigger" 2>/dev/null || true
            echo 500 > "$PWR_LED_PATH/delay_on" 2>/dev/null || true
            echo 500 > "$PWR_LED_PATH/delay_off" 2>/dev/null || true
            ;;
        default)
            echo "default-on" > "$PWR_LED_PATH/trigger" 2>/dev/null || true
            ;;
    esac
}

# ---- Undervoltage detection ----

# vcgencmd get_throttled returns a hex bitmask:
#   Bit 0  (0x1)     = currently under-voltage (<4.63V)
#   Bit 1  (0x2)     = ARM frequency currently capped
#   Bit 2  (0x4)     = currently throttled
#   Bit 16 (0x10000) = under-voltage has occurred since boot
#   Bit 17 (0x20000) = ARM frequency capping has occurred
#   Bit 18 (0x40000) = throttling has occurred
#
# We check bit 0 (active under-voltage) for the urgent warning,
# and bit 16 (historical) for informational logging.

UNDERVOLTAGE_LOGGED=false

check_undervoltage() {
    # Returns 0 = under-voltage NOW, 1 = no under-voltage, 2 = vcgencmd unavailable
    if ! command -v vcgencmd >/dev/null 2>&1; then
        return 2
    fi

    local throttled
    throttled=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' || echo "")
    if [ -z "$throttled" ]; then
        return 2
    fi

    # Validate hex format before arithmetic expansion (malformed output
    # from vcgencmd on older kernels could cause a shell error)
    if [[ ! "$throttled" =~ ^0x[0-9a-fA-F]{1,8}$ ]]; then
        return 2
    fi

    # Convert hex to decimal for bitwise test
    local val=$((throttled))

    # Bit 0: currently under-voltage
    if (( val & 0x1 )); then
        if [ "$UNDERVOLTAGE_LOGGED" = false ]; then
            echo "[!] UNDERVOLTAGE DETECTED (vcgencmd: $throttled) — power source too weak!"
            echo "[!] Pi may become unstable. Check USB power supply / battery."
            UNDERVOLTAGE_LOGGED=true
        fi
        return 0
    fi

    # Bit 16: under-voltage occurred since boot (not active now)
    if (( val & 0x10000 )); then
        if [ "$UNDERVOLTAGE_LOGGED" = false ]; then
            echo "[!] Under-voltage occurred since boot (vcgencmd: $throttled) — monitor power source"
            UNDERVOLTAGE_LOGGED=true
        fi
    else
        # Voltage is fine now, reset logging flag so we log again if it recurs
        UNDERVOLTAGE_LOGGED=false
    fi

    return 1
}

# ---- WiFi dongle watchdog ----

WIFI_RECOVERY_ATTEMPTED=false
WIFI_LOST_SINCE=0

check_wifi_dongle() {
    # Returns 0 = dongle OK and in mesh, 1 = dongle missing, 2 = dongle present but not in mesh
    if [ ! -d /sys/class/net/wlan1 ]; then
        return 1  # interface gone
    fi
    # wlan1 exists — but is it registered in batman-adv?
    # After a quick unplug/replug, wlan1 comes back in "managed" mode,
    # not "mesh point" mode, and is not in bat0. Detect this.
    if command -v batctl >/dev/null 2>&1; then
        if ! batctl if 2>/dev/null | grep -q "wlan1"; then
            return 2  # present but not in mesh
        fi
    fi
    WIFI_LOST_SINCE=0
    WIFI_RECOVERY_ATTEMPTED=false
    return 0
}

attempt_wifi_recovery() {
    # Try to recover the WiFi dongle without physical replug.
    # Three escalating strategies:
    #   1. USB device reset (usbreset) — sends USB RESET signal
    #   2. USB unbind/rebind via sysfs — simulates physical replug at kernel level
    #   3. Driver reload (modprobe -r/modprobe) — reinitializes firmware
    # Returns 0 = recovered, 1 = still broken (needs physical replug)

    if [ "$WIFI_RECOVERY_ATTEMPTED" = true ]; then
        return 1  # already tried all strategies
    fi
    WIFI_RECOVERY_ATTEMPTED=true

    echo "[!] WiFi dongle lost — attempting recovery..."

    # Find the AR9271 USB device
    local usb_bus usb_dev usb_port
    usb_bus=$(lsusb 2>/dev/null | grep -i "0cf3:9271" | head -1 | sed 's/Bus \([0-9]*\) Device \([0-9]*\).*/\/dev\/bus\/usb\/\1\/\2/')
    # Find sysfs USB port path (e.g., "3-2" from dmesg or sysfs)
    usb_port=$(ls /sys/bus/usb/drivers/ath9k_htc/ 2>/dev/null | grep -E '^[0-9]+-[0-9]' | head -1)

    # ---- Strategy 1: USB device reset ----
    if [ -n "$usb_bus" ] && [ -e "$usb_bus" ]; then
        echo "[+] Strategy 1: USB device reset ($usb_bus)"
        usbreset "$usb_bus" 2>/dev/null || true
        sleep 5
        if [ -d /sys/class/net/wlan1 ]; then
            echo "[+] Strategy 1 succeeded!"
            _wifi_recovery_restart_mesh
            return 0
        fi
    fi

    # ---- Strategy 2: USB unbind/rebind ----
    if [ -n "$usb_port" ]; then
        echo "[+] Strategy 2: USB unbind/rebind ($usb_port)"
        echo "$usb_port" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
        sleep 3
        echo "$usb_port" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
        sleep 5
        if [ -d /sys/class/net/wlan1 ]; then
            echo "[+] Strategy 2 succeeded!"
            _wifi_recovery_restart_mesh
            return 0
        fi
    else
        # Try to find port from dmesg
        usb_port=$(dmesg 2>/dev/null | grep -oP 'usb \K[0-9]+-[0-9]+(?=:.*ath9k)' | tail -1)
        if [ -n "$usb_port" ]; then
            echo "[+] Strategy 2: USB unbind/rebind ($usb_port from dmesg)"
            echo "$usb_port" > /sys/bus/usb/drivers/usb/unbind 2>/dev/null || true
            sleep 3
            echo "$usb_port" > /sys/bus/usb/drivers/usb/bind 2>/dev/null || true
            sleep 5
            if [ -d /sys/class/net/wlan1 ]; then
                echo "[+] Strategy 2 succeeded!"
                _wifi_recovery_restart_mesh
                return 0
            fi
        fi
    fi

    # ---- Strategy 3: Full driver reload ----
    echo "[+] Strategy 3: Full driver reload"
    modprobe -r ath9k_htc 2>/dev/null || true
    sleep 3
    modprobe ath9k_htc 2>/dev/null || true
    sleep 5
    if [ -d /sys/class/net/wlan1 ]; then
        echo "[+] Strategy 3 succeeded!"
        _wifi_recovery_restart_mesh
        return 0
    fi

    echo "[!] All recovery strategies FAILED — needs physical USB replug"
    return 1
}

_wifi_recovery_restart_mesh() {
    systemctl restart nightwatch-mesh 2>/dev/null || true
    sleep 5
    systemctl restart nightwatch-discovery 2>/dev/null || true
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
    check_svc ngircd

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
    # Check undervoltage first
    local uv=0
    check_undervoltage || uv=$?
    if [ "$uv" -eq 0 ]; then
        echo "*** UNDER-VOLTAGE — power source too low! ***"
    fi

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
    echo "Power:"
    if command -v vcgencmd >/dev/null 2>&1; then
        local throttled
        throttled=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' || echo "unavailable")
        local val=0
        if [[ "$throttled" =~ ^0x[0-9a-fA-F]{1,8}$ ]]; then
            val=$((throttled))
        fi
        printf "  vcgencmd throttled: %s" "$throttled"
        if (( val & 0x1 )); then
            printf "  *** UNDER-VOLTAGE NOW ***"
        elif (( val & 0x10000 )); then
            printf "  (under-voltage occurred since boot)"
        fi
        echo ""
        # Show CPU temperature too — useful for power/thermal debugging
        local temp
        temp=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "?")
        printf "  CPU temperature: %s°C\n" "$temp"
    else
        echo "  vcgencmd not available"
    fi

    echo ""
    echo "LED: $LED_PATH (trigger: $(cat "$LED_PATH/trigger" 2>/dev/null | grep -oP '\[\K[^\]]+' || echo 'unknown'))"
    if [ -n "$PWR_LED_PATH" ]; then
        echo "PWR: $PWR_LED_PATH (trigger: $(cat "$PWR_LED_PATH/trigger" 2>/dev/null | grep -oP '\[\K[^\]]+' || echo 'unknown'))"
    fi
}

# ---- Main ----

case "${1:-}" in
    start)
        echo "[+] Nightwatch LED status indicator starting"
        echo "[+] ACT LED: $LED_PATH"
        [ -n "$PWR_LED_PATH" ] && echo "[+] PWR LED: $PWR_LED_PATH"

        # Start with heartbeat (booting)
        led_heartbeat
        CURRENT_STATE=""
        STARTING_SINCE=0  # timestamp when we first entered "starting" state

        # Loop forever, checking health every 10 seconds
        while true; do
            # Undervoltage takes priority over everything
            uv_rc=0
            check_undervoltage || uv_rc=$?

            if [ "$uv_rc" -eq 0 ]; then
                # Active under-voltage — triple blink ACT LED + blink PWR LED
                if [ "$CURRENT_STATE" != "undervoltage" ]; then
                    CURRENT_STATE="undervoltage"
                    pwr_led_set blink
                fi
                # Triple-blink is manual (not a trigger), so we call it each iteration
                # It takes ~1.3s, and we skip the normal sleep to keep the pattern tight
                led_triple_blink
                continue
            fi

            # Restore PWR LED if we were in undervoltage state
            if [ "$CURRENT_STATE" = "undervoltage" ]; then
                pwr_led_set default
            fi

            # WiFi dongle crash detection (priority 2, after undervoltage)
            wifi_ok=0
            check_wifi_dongle || wifi_ok=$?

            # wlan1 exists but not in batman — quick replug or driver reset
            if [ "$wifi_ok" -eq 2 ]; then
                echo "[!] WiFi dongle present but not in mesh — restarting mesh..."
                led_heartbeat
                CURRENT_STATE="starting"
                STARTING_SINCE=$(date +%s)
                systemctl restart nightwatch-mesh 2>/dev/null || true
                sleep 10
                systemctl restart nightwatch-discovery 2>/dev/null || true
                continue
            fi

            if [ "$wifi_ok" -eq 1 ]; then
                if [ "$WIFI_LOST_SINCE" -eq 0 ]; then
                    WIFI_LOST_SINCE=$(date +%s)
                    echo "[!] WiFi dongle (wlan1) disappeared!"
                fi

                # Wait 30s before attempting recovery (dongle might be re-enumerating)
                now=$(date +%s)
                if [ $(( now - WIFI_LOST_SINCE )) -ge 30 ]; then
                    if [ "$WIFI_RECOVERY_ATTEMPTED" = false ]; then
                        attempt_wifi_recovery && { CURRENT_STATE=""; continue; }
                    fi
                    # Recovery failed — show double blink (needs physical replug)
                    if [ "$CURRENT_STATE" != "wifi_crashed" ]; then
                        CURRENT_STATE="wifi_crashed"
                        pwr_led_set blink
                        echo "[!] WiFi dongle needs physical replug — LED: double blink"
                        # Write to boot partition for macOS diagnosis
                        BOOT_ERR=""
                        for b in /boot/firmware /boot; do [ -f "$b/cmdline.txt" ] && BOOT_ERR="$b/nightwatch-error.log" && break; done
                        if [ -n "$BOOT_ERR" ]; then
                            {
                                echo "=== WiFi dongle crashed — $(date) ==="
                                echo "wlan1 interface missing. USB WiFi dongle needs physical replug."
                                echo ""
                                echo "USB devices:"
                                lsusb 2>/dev/null || true
                                echo ""
                                echo "dmesg (last WiFi errors):"
                                dmesg 2>/dev/null | grep -iE "ath9k|wlan|usb.*error|firmware" | tail -15 || true
                            } > "$BOOT_ERR" 2>/dev/null || true
                        fi
                    fi
                    led_wifi_crash_blink
                    continue
                fi
            fi

            # WiFi dongle came back after being gone — restart mesh so wlan1
            # is reconfigured in mesh point mode (it comes back as "managed").
            # Triggers whether dongle was gone for 5s or 5min.
            if [ "$WIFI_LOST_SINCE" -gt 0 ] && [ "$wifi_ok" -eq 0 ]; then
                echo "[+] WiFi dongle recovered! Restarting mesh and discovery..."
                led_heartbeat
                CURRENT_STATE="starting"
                STARTING_SINCE=$(date +%s)
                systemctl restart nightwatch-mesh 2>/dev/null || true
                sleep 10
                systemctl restart nightwatch-discovery 2>/dev/null || true
                pwr_led_set default
                WIFI_RECOVERY_ATTEMPTED=false
                WIFI_LOST_SINCE=0
                continue
            fi

            rc=0
            check_ready || rc=$?

            case "$rc" in
                0)
                    if [ "$CURRENT_STATE" != "ready" ]; then
                        led_ready
                        CURRENT_STATE="ready"
                        STARTING_SINCE=0
                    fi
                    ;;
                1)
                    if [ "$CURRENT_STATE" != "error" ]; then
                        led_fast_blink
                        CURRENT_STATE="error"
                        STARTING_SINCE=0
                        # Write error summary to boot partition (FAT32 — readable from macOS without sudo)
                        BOOT_ERR=""
                        for b in /boot/firmware /boot; do [ -f "$b/cmdline.txt" ] && BOOT_ERR="$b/nightwatch-error.log" && break; done
                        if [ -n "$BOOT_ERR" ]; then
                            {
                                echo "=== Nightwatch service error — $(date) ==="
                                for svc in nightwatch-mesh nightwatch-app nightwatch-discovery nightwatch-bridge; do
                                    state=$(systemctl show -p ActiveState --value "$svc" 2>/dev/null || echo "unknown")
                                    printf "  %-35s %s\n" "$svc" "$state"
                                    if [ "$state" != "active" ]; then
                                        systemctl status "$svc" --no-pager -n 20 2>/dev/null | tail -20 || true
                                    fi
                                done
                                echo ""
                                echo "Interfaces:"
                                ip link show 2>/dev/null | grep -E "^[0-9]+:|bat0|br0|wlan" || true
                            } > "$BOOT_ERR" 2>/dev/null || true
                        fi
                    fi
                    ;;
                2)
                    if [ "$CURRENT_STATE" != "starting" ]; then
                        led_heartbeat
                        CURRENT_STATE="starting"
                        STARTING_SINCE=$(date +%s)
                    else
                        # Escalate to error if stuck in "starting" for more than 5 minutes
                        now=$(date +%s)
                        if [ "$STARTING_SINCE" -gt 0 ] && [ $(( now - STARTING_SINCE )) -ge 300 ]; then
                            echo "[!] Services stuck in starting state for 5+ minutes — escalating LED to error"
                            led_fast_blink
                            CURRENT_STATE="error"
                            STARTING_SINCE=0
                        fi
                    fi
                    ;;
            esac

            # Blink manually instead of sleeping — no kernel triggers that get stuck.
            # Each cycle re-checks health after ~10s of blinking.
            case "$CURRENT_STATE" in
                ready)
                    for _blink in 1 2 3 4 5; do led_ready_cycle; done
                    ;;
                error)
                    for _blink in $(seq 1 50); do led_fast_blink_cycle; done
                    ;;
                starting|"")
                    for _blink in 1 2 3 4 5 6 7 8 9 10; do led_heartbeat_cycle; done
                    ;;
                *)
                    sleep 10
                    ;;
            esac
        done
        ;;

    stop)
        echo "[+] Restoring default LED behavior"
        led_restore_default
        pwr_led_set default
        ;;

    status)
        print_status
        ;;

    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
