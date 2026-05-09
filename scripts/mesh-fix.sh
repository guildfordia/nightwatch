#!/bin/bash
# Ensure sbin paths are available (iw, batctl, ip are in /usr/sbin on some systems)
export PATH="/usr/sbin:/sbin:$PATH"

# Nightwatch mesh network script
# 802.11s + batman-adv + Linux bridge for client access
#
# Architecture:
#   wlan1 (USB dongle 1) → 802.11s mesh → batman-adv (bat0)
#   wlan2 (USB dongle 2) → hostapd AP (802.11r) → bridge (br0) with bat0
#   wlan0 (onboard)      → internet + Tailscale (never touched)
#   br0 gets the mesh IP; bat0 is added manually, wlan2 is added by hostapd

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$PROJECT_DIR/.env"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

load_env "$ENV_FILE"
resolve_node_mode

# Defaults
MESH_IFACE="${MESH_IFACE:-wlan1}"
AP_IFACE="${AP_IFACE:-wlan2}"
AP_CHANNEL="${AP_CHANNEL:-6}"
AP_BSSID="${AP_BSSID:-02:00:4E:57:00:01}"
WIFI_SSID="${WIFI_SSID:-Nightwatch}"
WIFI_PASSWORD="${WIFI_PASSWORD:-Nightwatch}"
BAT_IFACE="${BAT_IFACE:-bat0}"
BR_IFACE="${BR_IFACE:-br0}"
MESH_ID="${MESH_ID:-nightwatch}"
FREQ="${FREQ:-2412}"
MESH_SAE_PASSWORD="${MESH_SAE_PASSWORD:-}"

if [ -z "$MESH_IP" ]; then
    echo "[-] Error: MESH_IP not set in $ENV_FILE"
    exit 1
fi

if [ -z "${PI_NUMBER:-}" ]; then
    echo "[-] Error: PI_NUMBER not set in $ENV_FILE"
    exit 1
fi

# Validate MESH_IP is a valid IPv4 address (strip CIDR suffix for check)
MESH_IP_CHECK="${MESH_IP%/*}"
if [[ ! "$MESH_IP_CHECK" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "[-] Error: Invalid MESH_IP: $MESH_IP"
    exit 1
fi

# Ensure CIDR notation
if [[ "$MESH_IP" != *"/"* ]]; then
    MESH_IP="${MESH_IP}/24"
fi

# ---- Helper functions ----

load_batman_module() {
    if ! lsmod | grep -q batman_adv; then
        echo "[+] Loading batman-adv kernel module..."
        modprobe batman-adv
    fi
    echo "[+] batman-adv version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'unknown')"
}

# wait_for_ap_interface <iface>
# Waits for the AP WiFi dongle (wlan2) to appear, with USB reset recovery.
# IMPORTANT: Does NOT use modprobe -r ath9k_htc (would kill wlan1's mesh too).
# Instead, resets the specific USB device for the second AR9271.
wait_for_ap_interface() {
    local AP_IF="$1"
    echo "[+] Waiting for AP interface $AP_IF..."
    local FOUND=false
    for _wait in $(seq 1 30); do
        if ip link show "$AP_IF" >/dev/null 2>&1; then
            echo "[+] $AP_IF is available"
            FOUND=true
            break
        fi
        if [ $((_wait % 5)) -eq 0 ]; then
            echo "[.] Still waiting for $AP_IF... (${_wait}s/30s)"
        fi
        sleep 1
    done

    # If missing, try USB reset for the second AR9271 only
    if [ "$FOUND" = false ]; then
        echo "[!] $AP_IF not found after 30s — attempting USB reset for second AR9271..."
        local AR9271_COUNT=0
        for dev in /sys/bus/usb/devices/*/idVendor; do
            local USB_DEV
            USB_DEV=$(dirname "$dev")
            if [ "$(cat "$USB_DEV/idVendor" 2>/dev/null)" = "0cf3" ] && \
               [ "$(cat "$USB_DEV/idProduct" 2>/dev/null)" = "9271" ]; then
                AR9271_COUNT=$((AR9271_COUNT + 1))
                # Reset the second AR9271 (first is the mesh dongle)
                if [ "$AR9271_COUNT" -eq 2 ]; then
                    echo "[+] Resetting second AR9271 at $USB_DEV..."
                    echo 0 > "$USB_DEV/authorized" 2>/dev/null || true
                    sleep 2
                    echo 1 > "$USB_DEV/authorized" 2>/dev/null || true
                    break
                fi
            fi
        done
        # Wait for recovery
        for _wait in $(seq 1 15); do
            if ip link show "$AP_IF" >/dev/null 2>&1; then
                echo "[+] $AP_IF recovered after USB reset"
                FOUND=true
                break
            fi
            sleep 1
        done
    fi

    if [ "$FOUND" = false ]; then
        echo "[-] $AP_IF not found — WiFi AP will not be available"
        return 1
    fi

    # Tell NetworkManager to leave it alone
    nmcli dev set "$AP_IF" managed no 2>/dev/null || true
    return 0
}

setup_mesh_interface() {
    echo "[+] Configuring $MESH_IFACE for 802.11s mesh..."

    # Check if already in mesh mode (e.g. after a service restart where
    # the stop handler intentionally left wlan1 alone)
    CURRENT_TYPE=$(iw dev "$MESH_IFACE" info 2>/dev/null | grep type | awk '{print $2}')
    if [ "$CURRENT_TYPE" = "mesh" ]; then
        echo "[+] $MESH_IFACE already in mesh mode — skipping reconfiguration"
        ip link set "$MESH_IFACE" up 2>/dev/null || true
        return 0
    fi

    # Kill anything holding the interface (NetworkManager, wpa_supplicant)
    nmcli dev set "$MESH_IFACE" managed no 2>/dev/null || true
    pkill -f "wpa_supplicant.*$MESH_IFACE" 2>/dev/null || true
    sleep 1
    # Force-kill if SIGTERM was ignored
    if pgrep -f "wpa_supplicant.*$MESH_IFACE" >/dev/null 2>&1; then
        pkill -9 -f "wpa_supplicant.*$MESH_IFACE" 2>/dev/null || true
        sleep 1
    fi

    # Try setting mesh mode directly first — the driver reload is only needed
    # when wpa_supplicant has left the firmware in a bad state.
    ip link set "$MESH_IFACE" down 2>/dev/null || true
    if iw dev "$MESH_IFACE" set type mesh 2>/dev/null; then
        echo "[+] $MESH_IFACE set to mesh mode directly (no driver reload needed)"
        ip link set "$MESH_IFACE" up
        sleep 1

        IFACE_TYPE=$(iw dev "$MESH_IFACE" info 2>/dev/null | grep type | awk '{print $2}')
        if [ "$IFACE_TYPE" = "mesh" ]; then
            # Skip the rest of setup_mesh_interface — jump to mesh join below
            _SKIP_MODE_SETUP=true
        fi
    fi

    if [ "${_SKIP_MODE_SETUP:-}" != "true" ]; then
        # Direct mode set failed — reload the driver to reset firmware state.
        # The ath9k_htc firmware crashes when wlan1 is cycled down/up while
        # NetworkManager or wpa_supplicant are interacting with it.
        echo "[+] Reloading ath9k_htc driver for clean mesh setup..."
        modprobe -r ath9k_htc 2>/dev/null || true
        sleep 2
        modprobe ath9k_htc 2>/dev/null || true

        # Wait for interface to reappear after driver reload
        RELOAD_OK=false
        for _drv_wait in $(seq 1 15); do
            if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
                echo "[+] $MESH_IFACE reappeared after driver reload"
                RELOAD_OK=true
                break
            fi
            sleep 1
        done

        # If driver reload failed, try USB authorized reset (more reliable on Pi 5)
        if [ "$RELOAD_OK" = false ]; then
            echo "[!] Driver reload failed — trying USB device reset..."
            modprobe -r ath9k_htc 2>/dev/null || true
            for dev in /sys/bus/usb/devices/*/idVendor; do
                USB_DEV=$(dirname "$dev")
                if [ "$(cat "$USB_DEV/idVendor" 2>/dev/null)" = "0cf3" ] && \
                   [ "$(cat "$USB_DEV/idProduct" 2>/dev/null)" = "9271" ]; then
                    echo "[+] Resetting AR9271 at $USB_DEV..."
                    echo 0 > "$USB_DEV/authorized" 2>/dev/null || true
                    sleep 2
                    echo 1 > "$USB_DEV/authorized" 2>/dev/null || true
                    break
                fi
            done
            sleep 2
            modprobe ath9k_htc 2>/dev/null || true
            for _drv_wait in $(seq 1 15); do
                if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
                    echo "[+] $MESH_IFACE recovered after USB reset"
                    RELOAD_OK=true
                    break
                fi
                sleep 1
            done
            if [ "$RELOAD_OK" = false ]; then
                echo "[-] $MESH_IFACE did not reappear after driver + USB reset"
                exit 1
            fi
        fi
    fi

    # Tell NM to leave it alone (again, after driver reload re-creates the device)
    nmcli dev set "$MESH_IFACE" managed no 2>/dev/null || true
    sleep 1

    if [ "${_SKIP_MODE_SETUP:-}" != "true" ]; then
        # Bring down and set mesh type
        ip link set "$MESH_IFACE" down 2>/dev/null || true
        if ! iw dev "$MESH_IFACE" set type mesh; then
            echo "[-] Failed to set $MESH_IFACE to mesh mode, retrying..."
            sleep 2
            iw dev "$MESH_IFACE" set type mesh
        fi
        ip link set "$MESH_IFACE" up

        sleep 1

        # Verify mesh mode
        IFACE_TYPE=$(iw dev "$MESH_IFACE" info 2>/dev/null | grep type | awk '{print $2}')
        if [ "$IFACE_TYPE" != "mesh" ]; then
            echo "[-] Error: $MESH_IFACE is '$IFACE_TYPE' instead of 'mesh'"
            echo "[-] Check if another process is managing this interface"
            exit 1
        fi
    fi

    # Join 802.11s mesh
    if [ -n "$MESH_SAE_PASSWORD" ]; then
        echo "[+] Joining encrypted mesh '$MESH_ID' on $FREQ MHz (SAE)..."
        # SAE encryption requires wpa_supplicant — generate config
        WPA_CONF=$(mktemp /run/nightwatch-mesh-wpa.XXXXXX)
        chmod 600 "$WPA_CONF"
        cat > "$WPA_CONF" << WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
network={
    ssid="$MESH_ID"
    mode=5
    frequency=$FREQ
    key_mgmt=SAE
    sae_password="$MESH_SAE_PASSWORD"
    ieee80211w=2
    mesh_fwding=0
}
WPAEOF
        wpa_supplicant -B -i "$MESH_IFACE" -c "$WPA_CONF" -D nl80211
        # Clean up WPA config after wpa_supplicant has fully started (contains SAE password)
        # Wait for the wpa_supplicant control socket to confirm it's running
        (
            for _try in $(seq 1 10); do
                if [ -e "/var/run/wpa_supplicant/$MESH_IFACE" ]; then
                    break
                fi
                sleep 1
            done
            rm -f "$WPA_CONF"
        ) &
    else
        echo "[+] Joining open mesh '$MESH_ID' on $FREQ MHz..."
        iw dev "$MESH_IFACE" mesh join "$MESH_ID" freq "$FREQ"
    fi

    sleep 1

    # Disable 802.11s HWMP forwarding so batman-adv can route unicast frames.
    # Running HWMP and batman-adv together causes every unicast packet to be
    # dropped while HWMP resolves a path — broadcasts/OGMs/ARP still flow, so
    # the failure looks like "mesh layer sees everyone but pings die".
    # Must use `iw set mesh_param` — the /sys/class/net/.../mesh/mesh_fwding
    # sysfs path was removed in recent kernels.
    iw dev "$MESH_IFACE" set mesh_param mesh_fwding 0

    # Raise MTU so batman-adv doesn't have to fragment (batman adds ~28 bytes
    # of header; at the default 1500 the extra bytes force L2 fragmentation).
    ip link set "$MESH_IFACE" mtu 1532

    echo "[+] 802.11s mesh interface ready (HWMP off, MTU 1532)"
}

setup_batman() {
    echo "[+] Setting up batman-adv on $BAT_IFACE..."

    # Add mesh interface to batman
    if ! batctl meshif "$BAT_IFACE" if add "$MESH_IFACE" 2>/dev/null && \
       ! batctl if add "$MESH_IFACE" 2>/dev/null; then
        echo "[-] Error: failed to add $MESH_IFACE to batman-adv (is batctl installed?)"
        return 1
    fi

    # Bring up bat0 (no IP here — br0 gets the IP)
    ip link set "$BAT_IFACE" up

    # Enable distributed ARP table for efficiency
    batctl meshif "$BAT_IFACE" dat 1 2>/dev/null || \
        batctl dat 1 2>/dev/null || true

    # Enable bridge loop avoidance (needed when eth0 is bridged)
    batctl meshif "$BAT_IFACE" bla 1 2>/dev/null || \
        batctl bla 1 2>/dev/null || true

    # Faster mesh reconvergence: reduce OGM interval from 1000ms to 500ms
    # so nodes detect topology changes twice as fast after a link drop
    batctl meshif "$BAT_IFACE" orig_interval 500 2>/dev/null || \
        batctl orig_interval 500 2>/dev/null || true

    echo "[+] batman-adv $BAT_IFACE is up"
}

setup_client_bridge() {
    echo "[+] Creating Linux bridge $BR_IFACE ($BAT_IFACE + hostapd AP)..."

    # br0 bridges bat0 (mesh) with the hostapd AP interface (wlan2).
    # bat0 is added here; wlan2 is added automatically by hostapd via its
    # bridge=br0 directive (hostapd must start AFTER br0 exists).

    # Remove any existing bridge
    ip link set "$BR_IFACE" down 2>/dev/null || true
    ip link del "$BR_IFACE" 2>/dev/null || true

    # Strip IPs from bat0 — only the bridge itself gets an IP
    ip addr flush dev "$BAT_IFACE" 2>/dev/null || true

    # Create bridge with bat0 only (hostapd will add AP_IFACE)
    ip link add name "$BR_IFACE" type bridge
    if ! ip link set "$BAT_IFACE" master "$BR_IFACE"; then
        echo "[-] Failed to add $BAT_IFACE to bridge $BR_IFACE"
        return 1
    fi

    # Pin br0's MAC to bat0's MAC BEFORE hostapd adds wlan2.
    # Without this, the bridge adopts wlan2's MAC (the AP dongle's hardware MAC)
    # which confuses batman-adv's DAT — the bridge looks like a different
    # originator than bat0, breaking cross-node ARP resolution.
    BRIDGE_MAC=$(cat /sys/class/net/"$BAT_IFACE"/address 2>/dev/null)
    if [ -n "$BRIDGE_MAC" ]; then
        ip link set "$BR_IFACE" address "$BRIDGE_MAC"
    fi

    # Bring up bridge and assign mesh IP
    ip link set "$BR_IFACE" up
    ip addr add "$MESH_IP" dev "$BR_IFACE"

    # Shared IP across all nodes — users can always type http://192.168.199.1
    ip addr add 192.168.199.1/32 dev "$BR_IFACE" 2>/dev/null || true

    # Half-measure for §3.3 #9 (anchor service IP): each node owns
    # 192.168.199.1 with its own br0 MAC, and nightwatch-arp-refresh sends
    # a gratuitous ARP on every AP-STA-CONNECTED to refresh phone caches
    # post-roaming. The frame must NOT leak onto bat0: it would corrupt
    # peer nodes' STA caches (different MAC for the same IP) and trigger
    # batman-adv DAT/BLA flap. Drop any ARP for 192.168.199.1 going out
    # bat0. Idempotent: flush first to survive a service restart.
    if command -v ebtables >/dev/null 2>&1; then
        ebtables -t filter -D FORWARD -o "$BAT_IFACE" -p arp --arp-ip-src 192.168.199.1 -j DROP 2>/dev/null || true
        ebtables -t filter -D FORWARD -o "$BAT_IFACE" -p arp --arp-ip-dst 192.168.199.1 -j DROP 2>/dev/null || true
        ebtables -t filter -A FORWARD -o "$BAT_IFACE" -p arp --arp-ip-src 192.168.199.1 -j DROP 2>/dev/null || true
        ebtables -t filter -A FORWARD -o "$BAT_IFACE" -p arp --arp-ip-dst 192.168.199.1 -j DROP 2>/dev/null || true
    fi

    echo "[+] Bridge $BR_IFACE is up with IP ${MESH_IP%/*} + 192.168.199.1 (shared)"
    echo "[+] Ports: $BAT_IFACE (mesh) — $AP_IFACE will be added by hostapd"
}

setup_sound_bridge() {
    # Sound-bridge mode: eth0 connects to a Mac Mini running nightwatch-sound.
    # eth0 is NOT added to the br0 bridge. Instead it gets its own subnet
    # (10.0.0.1/24) so the Pi can route traffic between mesh and Mac Mini.
    # Note: uses eth0 explicitly (not $AP_IFACE) since AP_IFACE is wlan2 in
    # the hostapd-based architecture, and the Mac Mini is always on ethernet.
    local SOUND_IFACE="eth0"
    echo "[+] Sound-bridge mode: configuring $SOUND_IFACE for Mac Mini (10.0.0.0/24)..."

    # Create br0 with ONLY bat0 (no eth0, no wlan2)
    ip link set "$BR_IFACE" down 2>/dev/null || true
    ip link del "$BR_IFACE" 2>/dev/null || true

    ip addr flush dev "$BAT_IFACE" 2>/dev/null || true
    ip addr flush dev "$SOUND_IFACE" 2>/dev/null || true

    # Release any DHCP lease on eth0
    if command -v dhcpcd >/dev/null 2>&1; then
        dhcpcd --release "$SOUND_IFACE" 2>/dev/null || true
    fi

    # Remove eth0's default route (no internet on this link)
    ip route del default dev "$SOUND_IFACE" 2>/dev/null || true

    # Tell NetworkManager to stop managing eth0
    if command -v nmcli >/dev/null 2>&1; then
        ETH_CON=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null | grep "$SOUND_IFACE" | head -1 | cut -d: -f1 || true)
        if [ -n "$ETH_CON" ]; then
            nmcli con down "$ETH_CON" 2>/dev/null || true
        fi
        nmcli dev set "$SOUND_IFACE" managed no 2>/dev/null || true
    fi

    # Bridge: only bat0 (mesh traffic), no eth0
    ip link add name "$BR_IFACE" type bridge
    ip link set "$BAT_IFACE" master "$BR_IFACE"

    # Pin br0's MAC to bat0's so it stays unique across nodes
    BRIDGE_MAC=$(cat /sys/class/net/"$BAT_IFACE"/address 2>/dev/null)
    if [ -n "$BRIDGE_MAC" ]; then
        ip link set "$BR_IFACE" address "$BRIDGE_MAC"
    fi

    ip link set "$BR_IFACE" up
    ip addr add "$MESH_IP" dev "$BR_IFACE"

    echo "[+] Bridge $BR_IFACE up with IP ${MESH_IP%/*} (bat0 only, no eth0)"

    # eth0: static IP on a separate subnet for the Mac Mini
    ip link set "$SOUND_IFACE" up
    ip addr add 10.0.0.1/24 dev "$SOUND_IFACE"

    echo "[+] $SOUND_IFACE configured: 10.0.0.1/24 (Mac Mini subnet)"

    # Enable IP forwarding so Mac Mini (10.0.0.x) can reach the mesh (192.168.199.x)
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    echo "[+] IP forwarding enabled (mesh <-> Mac Mini routing)"
}

start_dnsmasq() {
    DNSMASQ_CONF="$PROJECT_DIR/dnsmasq/dnsmasq.conf"
    DNSMASQ_PID="/var/run/dnsmasq-nightwatch.pid"

    # Kill any existing Nightwatch dnsmasq instance
    if [ -f "$DNSMASQ_PID" ]; then
        OLD_PID=$(cat "$DNSMASQ_PID")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            # Verify it's actually dnsmasq before killing (PID could be recycled)
            if ps -p "$OLD_PID" -o comm= 2>/dev/null | grep -q '^dnsmasq'; then
                kill "$OLD_PID" 2>/dev/null || true
            else
                echo "[!] PID $OLD_PID is not dnsmasq — removing stale PID file"
            fi
        fi
        rm -f "$DNSMASQ_PID"
    fi

    # Kill any dnsmasq instances using our config — avoids duplicates that
    # cause DHCP to silently fail. Uses pkill -f to match only Nightwatch's
    # dnsmasq, not system dnsmasq or other services.
    pkill -9 -f "dnsmasq --conf-file=$PROJECT_DIR" 2>/dev/null || true
    systemctl stop dnsmasq 2>/dev/null || true
    sleep 1

    # Always regenerate dnsmasq config on start so .env changes take effect.
    # Previously only generated if missing — stale configs caused DHCP to break
    # after changing PI_NUMBER or MESH_IP without manually removing the file.
    local node_num="${PI_NUMBER:-1}"
    local mesh_ip="${MESH_IP%/*}"
    local sb_flag=0
    if [ "$NODE_MODE" = "sound-bridge" ]; then
        sb_flag=1
    fi
    generate_dnsmasq_conf "$DNSMASQ_CONF" "$node_num" "$mesh_ip" "$sb_flag"
    if [ "$sb_flag" = "1" ]; then
        echo "[+] dnsmasq.conf regenerated for node $node_num (mesh $mesh_ip + eth0 10.0.0.0/24)"
    else
        echo "[+] dnsmasq.conf regenerated for node $node_num (mesh IP $mesh_ip)"
    fi

    if [ -f "$DNSMASQ_CONF" ]; then
        echo "[+] Starting dnsmasq (DHCP + captive portal DNS on $BR_IFACE)..."
        dnsmasq --conf-file="$DNSMASQ_CONF"
        echo "[+] dnsmasq running — WiFi clients will get IPs and captive portal"
    else
        echo "[!] dnsmasq config generation failed — captive portal will not work"
    fi

    # ---- DNS + HTTP redirect iptables rules ----
    # DNS: Intercept ALL DNS traffic (port 53) — modern phones use hardcoded
    # DNS (8.8.8.8, 1.1.1.1) bypassing DHCP. Without this, DNS fails.
    # HTTP: Redirect port 80 so phones that try any HTTP URL land on the chat.
    # Combined with nginx captive portal detection responses (/generate_204 etc.),
    # phones open the REAL browser instead of the restricted WebView.
    local LOCAL_IP="${MESH_IP%/*}"
    echo "[+] Setting up DNS + HTTP redirect iptables rules..."

    # Use iptables-restore for atomic rule application (all-or-nothing).
    if command -v iptables-restore >/dev/null 2>&1; then
        RULES_FILE=$(mktemp /tmp/nightwatch-iptables.XXXXXX)
        iptables-save -t nat 2>/dev/null | grep -v "nightwatch-captive" > "$RULES_FILE" || true
        sed -i '/^COMMIT$/d' "$RULES_FILE"
        cat >> "$RULES_FILE" << IPTEOF
-A PREROUTING -i $BR_IFACE -p udp --dport 53 ! -d $LOCAL_IP -j DNAT --to-destination $LOCAL_IP:53 -m comment --comment "nightwatch-captive"
-A PREROUTING -i $BR_IFACE -p tcp --dport 53 ! -d $LOCAL_IP -j DNAT --to-destination $LOCAL_IP:53 -m comment --comment "nightwatch-captive"
-A PREROUTING -i $BR_IFACE -p tcp --dport 853 -j DNAT --to-destination $LOCAL_IP:53 -m comment --comment "nightwatch-captive"
-A PREROUTING -i $BR_IFACE -p tcp --dport 80 ! -d $LOCAL_IP -j DNAT --to-destination $LOCAL_IP:80 -m comment --comment "nightwatch-captive"
COMMIT
IPTEOF
        if iptables-restore -T nat < "$RULES_FILE" 2>/dev/null; then
            echo "[+] iptables rules applied atomically (DNS + HTTP redirect)"
            rm -f "$RULES_FILE"
        else
            echo "[!] iptables-restore failed — falling back to individual rules"
            rm -f "$RULES_FILE"
            iptables -t nat -C PREROUTING -i "$BR_IFACE" -p udp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53 2>/dev/null || \
                iptables -t nat -A PREROUTING -i "$BR_IFACE" -p udp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53
            iptables -t nat -C PREROUTING -i "$BR_IFACE" -p tcp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53 2>/dev/null || \
                iptables -t nat -A PREROUTING -i "$BR_IFACE" -p tcp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53
            iptables -t nat -C PREROUTING -i "$BR_IFACE" -p tcp --dport 853 -j DNAT --to-destination "$LOCAL_IP":53 2>/dev/null || \
                iptables -t nat -A PREROUTING -i "$BR_IFACE" -p tcp --dport 853 -j DNAT --to-destination "$LOCAL_IP":53
            iptables -t nat -C PREROUTING -i "$BR_IFACE" -p tcp --dport 80 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":80 2>/dev/null || \
                iptables -t nat -A PREROUTING -i "$BR_IFACE" -p tcp --dport 80 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":80
        fi
    else
        iptables -t nat -C PREROUTING -i "$BR_IFACE" -p udp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53 2>/dev/null || \
            iptables -t nat -A PREROUTING -i "$BR_IFACE" -p udp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53
        iptables -t nat -C PREROUTING -i "$BR_IFACE" -p tcp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53 2>/dev/null || \
            iptables -t nat -A PREROUTING -i "$BR_IFACE" -p tcp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53
        iptables -t nat -C PREROUTING -i "$BR_IFACE" -p tcp --dport 853 -j DNAT --to-destination "$LOCAL_IP":53 2>/dev/null || \
            iptables -t nat -A PREROUTING -i "$BR_IFACE" -p tcp --dport 853 -j DNAT --to-destination "$LOCAL_IP":53
        iptables -t nat -C PREROUTING -i "$BR_IFACE" -p tcp --dport 80 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":80 2>/dev/null || \
            iptables -t nat -A PREROUTING -i "$BR_IFACE" -p tcp --dport 80 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":80
    fi

    echo "[+] iptables rules active (DNS + HTTP redirect)"
}

start_hostapd() {
    local HOSTAPD_CONF="$PROJECT_DIR/hostapd/hostapd.conf"
    local HOSTAPD_PID="/var/run/hostapd-nightwatch.pid"

    # Kill any existing hostapd
    if [ -f "$HOSTAPD_PID" ]; then
        local OLD_PID
        OLD_PID=$(cat "$HOSTAPD_PID")
        if kill -0 "$OLD_PID" 2>/dev/null; then
            if ps -p "$OLD_PID" -o comm= 2>/dev/null | grep -q '^hostapd'; then
                kill "$OLD_PID" 2>/dev/null || true
                sleep 1
            fi
        fi
        rm -f "$HOSTAPD_PID"
    fi
    # Stop system hostapd to avoid port conflicts
    systemctl stop hostapd 2>/dev/null || true

    # Always regenerate config on start so .env changes (SSID, password, BSSID,
    # channel) take effect. Previously only generated if missing — stale configs
    # caused connection issues after changing settings.
    generate_hostapd_conf "$HOSTAPD_CONF" \
        "$AP_IFACE" "$BR_IFACE" \
        "$WIFI_SSID" "$WIFI_PASSWORD" \
        "$AP_CHANNEL" "$AP_BSSID"
    echo "[+] hostapd.conf regenerated (SSID: $WIFI_SSID, BSSID: $AP_BSSID, ch $AP_CHANNEL)"

    echo "[+] Starting hostapd (WiFi AP on $AP_IFACE, SSID '$WIFI_SSID')..."
    hostapd -B -P "$HOSTAPD_PID" "$HOSTAPD_CONF"
    sleep 2

    # Verify hostapd started and added AP_IFACE to bridge
    if [ -f "$HOSTAPD_PID" ] && kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; then
        echo "[+] hostapd running — AP broadcasting '$WIFI_SSID' (BSSID $AP_BSSID, ch $AP_CHANNEL)"
        # Wait for hostapd to add AP_IFACE to br0 (bridge= directive)
        # dnsmasq must not start until the bridge has all its ports
        for _brwait in $(seq 1 10); do
            if [ -d "/sys/class/net/$BR_IFACE/brif/$AP_IFACE" ]; then
                echo "[+] $AP_IFACE joined $BR_IFACE"
                break
            fi
            sleep 1
        done
        if [ ! -d "/sys/class/net/$BR_IFACE/brif/$AP_IFACE" ]; then
            echo "[!] Warning: $AP_IFACE did not join $BR_IFACE — DHCP may not reach WiFi clients"
        fi
    else
        echo "[!] hostapd failed to start — check $HOSTAPD_CONF"
        echo "[!] WiFi AP is unavailable; mesh network still operational"
    fi
}

setup_gateway() {
    if [ "$NODE_MODE" = "gateway" ]; then
        echo "[+] Configuring this node as a mesh gateway..."
        batctl meshif "$BAT_IFACE" gw_mode server 2>/dev/null || \
            batctl gw_mode server 2>/dev/null || true

        # Enable IP forwarding for internet sharing
        sysctl -w net.ipv4.ip_forward=1 > /dev/null

        # NAT for internet-bound traffic (wlan0 has internet via WiFi client)
        local INET_IFACE="${INET_IFACE:-wlan0}"
        # Only add rules if not already present (prevents duplicates on restart)
        iptables -t nat -C POSTROUTING -o "$INET_IFACE" -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -o "$INET_IFACE" -j MASQUERADE 2>/dev/null || true
        iptables -C FORWARD -i "$BR_IFACE" -o "$INET_IFACE" -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -i "$BR_IFACE" -o "$INET_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -C FORWARD -i "$INET_IFACE" -o "$BR_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
            iptables -A FORWARD -i "$INET_IFACE" -o "$BR_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

        echo "[+] Gateway mode enabled (NAT via $INET_IFACE)"
    else
        batctl meshif "$BAT_IFACE" gw_mode client 2>/dev/null || \
            batctl gw_mode client 2>/dev/null || true
        echo "[+] Gateway mode: client (will use mesh gateway if available)"
    fi
}

# ---- Main actions ----

case "$1" in
    start)
        echo "====================================="
        echo "  Nightwatch Mesh Network Starting"
        echo "====================================="
        echo ""

        # Wait for mesh interface to be available (USB dongle may take time)
        echo "[+] Waiting for $MESH_IFACE..."
        IFACE_FOUND=false
        for _wait in $(seq 1 30); do
            if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
                echo "[+] $MESH_IFACE is available"
                IFACE_FOUND=true
                break
            fi
            # Progress every 5 seconds so users know the system isn't frozen
            if [ $((_wait % 5)) -eq 0 ]; then
                echo "[.] Still waiting for $MESH_IFACE... (${_wait}s/30s)"
            fi
            sleep 1
        done

        # If still missing, try USB reset (ath9k_htc firmware may have crashed)
        # Find the device by vendor:product ID since the net/ subdirectory
        # disappears when the driver crashes
        if [ "$IFACE_FOUND" = false ]; then
            echo "[!] $MESH_IFACE not found after 30s — attempting USB reset..."
            USB_RESET_DONE=false
            for dev in /sys/bus/usb/devices/*/idVendor; do
                USB_DEV=$(dirname "$dev")
                if [ "$(cat "$USB_DEV/idVendor" 2>/dev/null)" = "0cf3" ] && \
                   [ "$(cat "$USB_DEV/idProduct" 2>/dev/null)" = "9271" ]; then
                    echo "[+] Found AR9271 at $USB_DEV — resetting..."
                    echo 0 > "$USB_DEV/authorized" 2>/dev/null || true
                    sleep 2
                    echo 1 > "$USB_DEV/authorized" 2>/dev/null || true
                    USB_RESET_DONE=true
                    break
                fi
            done
            if [ "$USB_RESET_DONE" = false ]; then
                echo "[-] AR9271 USB device not found in sysfs"
            fi
            for _wait in $(seq 1 15); do
                if ip link show "$MESH_IFACE" >/dev/null 2>&1; then
                    echo "[+] $MESH_IFACE recovered after USB reset"
                    IFACE_FOUND=true
                    break
                fi
                sleep 1
            done
        fi

        if [ "$IFACE_FOUND" = false ]; then
            echo "[-] Error: $MESH_IFACE not found after USB reset"
            echo "[-] Check that USB WiFi dongle is connected"
            exit 1
        fi

        check_deps iw batctl ip || exit 1

        # Clean up WPA config files on unexpected exit (contain SAE password)
        trap 'rm -f /run/nightwatch-mesh-wpa.* 2>/dev/null' EXIT

        echo "[+] Node mode: $NODE_MODE"

        load_batman_module
        setup_mesh_interface
        setup_batman

        # Wait for AP dongle (wlan2) — skip in sound-bridge mode (no AP needed)
        AP_AVAILABLE=false
        if [ "$NODE_MODE" != "sound-bridge" ]; then
            if wait_for_ap_interface "$AP_IFACE"; then
                AP_AVAILABLE=true
            fi
        fi

        if [ "$NODE_MODE" = "sound-bridge" ]; then
            # Sound-bridge: eth0 on separate subnet, not bridged
            setup_sound_bridge
            # Start hostapd if AP dongle is available (WiFi clients still need AP)
            if [ "$AP_AVAILABLE" = true ]; then
                start_hostapd
            fi
            start_dnsmasq
            # batman-adv gw_mode client (sound-bridge is not a gateway)
            batctl meshif "$BAT_IFACE" gw_mode client 2>/dev/null || \
                batctl gw_mode client 2>/dev/null || true
        else
            # mesh or gateway: bat0 bridged via br0, hostapd adds AP_IFACE
            for _attempt in 1 2 3; do
                if setup_client_bridge; then
                    break
                fi
                if [ "$_attempt" -eq 3 ]; then
                    echo "[!] Client bridge setup failed after 3 attempts — mesh still operational"
                    break
                fi
                echo "[!] Bridge setup failed (attempt $_attempt/3), retrying in ${_attempt}s..."
                sleep "$_attempt"
            done
            # Start hostapd (adds AP_IFACE to br0 via bridge= directive)
            if [ "$AP_AVAILABLE" = true ]; then
                start_hostapd
            fi
            start_dnsmasq
            setup_gateway
        fi

        echo ""
        echo "====================================="
        echo "  Mesh network is UP"
        echo "  Mode:    $NODE_MODE"
        echo "  Mesh IP: ${MESH_IP%/*} (on $BR_IFACE)"
        if [ "$NODE_MODE" = "sound-bridge" ]; then
        echo "  Bridge:  $BAT_IFACE → $BR_IFACE (no eth0)"
        echo "  eth0:    10.0.0.1/24 (Mac Mini)"
        else
        echo "  Bridge:  $BAT_IFACE + $AP_IFACE → $BR_IFACE (hostapd)"
        fi
        if [ "$AP_AVAILABLE" = true ]; then
        echo "  WiFi AP: $WIFI_SSID (BSSID $AP_BSSID, ch $AP_CHANNEL)"
        else
        echo "  WiFi AP: UNAVAILABLE ($AP_IFACE not found)"
        fi
        echo "====================================="

        # LED service starts After=nightwatch-app.service, so it only checks
        # health when everything is already up — no stale fast-blink on boot.
        ;;

    stop)
        echo "[+] Stopping Nightwatch mesh network..."

        # Stop hostapd (must stop before bridge teardown)
        HOSTAPD_PID="/var/run/hostapd-nightwatch.pid"
        if [ -f "$HOSTAPD_PID" ]; then
            OLD_PID=$(cat "$HOSTAPD_PID")
            if kill -0 "$OLD_PID" 2>/dev/null; then
                if ps -p "$OLD_PID" -o comm= 2>/dev/null | grep -q '^hostapd'; then
                    kill "$OLD_PID" 2>/dev/null || true
                else
                    echo "[!] PID $OLD_PID is not hostapd — removing stale PID file"
                fi
            fi
            rm -f "$HOSTAPD_PID"
        fi

        # Stop dnsmasq
        DNSMASQ_PID="/var/run/dnsmasq-nightwatch.pid"
        if [ -f "$DNSMASQ_PID" ]; then
            OLD_PID=$(cat "$DNSMASQ_PID")
            if kill -0 "$OLD_PID" 2>/dev/null; then
                if ps -p "$OLD_PID" -o comm= 2>/dev/null | grep -q '^dnsmasq'; then
                    kill "$OLD_PID" 2>/dev/null || true
                else
                    echo "[!] PID $OLD_PID is not dnsmasq — removing stale PID file"
                fi
            fi
            rm -f "$DNSMASQ_PID"
        fi

        # Tear down Linux bridge
        ip link set "$BR_IFACE" down 2>/dev/null || true
        ip link del "$BR_IFACE" 2>/dev/null || true

        # Remove mesh interface from batman
        batctl meshif "$BAT_IFACE" if del "$MESH_IFACE" 2>/dev/null || \
            batctl if del "$MESH_IFACE" 2>/dev/null || true

        # Bring down bat0
        ip link set "$BAT_IFACE" down 2>/dev/null || true

        # Clean up mesh wpa_supplicant (SAE mode only — don't kill internet wpa_supplicant)
        pkill -f "nightwatch-mesh-wpa" 2>/dev/null || true
        rm -f /run/nightwatch-mesh-wpa.* 2>/dev/null || true

        # Do NOT bring wlan1 down or leave mesh mode here.
        # The ath9k_htc firmware crashes when wlan1 is cycled down/up,
        # causing it to vanish from the system. Leaving wlan1 in mesh mode
        # is harmless — setup_mesh_interface handles any state on start.

        # NOTE: wlan0 is never touched — it provides internet/Tailscale

        # Clean up sound-bridge eth0 address if present
        ip addr del 10.0.0.1/24 dev eth0 2>/dev/null || true

        # Remove captive portal iptables rules
        LOCAL_IP="${MESH_IP%/*}"
        iptables -t nat -D PREROUTING -i "$BR_IFACE" -p udp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53 2>/dev/null || true
        iptables -t nat -D PREROUTING -i "$BR_IFACE" -p tcp --dport 53 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":53 2>/dev/null || true
        iptables -t nat -D PREROUTING -i "$BR_IFACE" -p tcp --dport 853 -j DNAT --to-destination "$LOCAL_IP":53 2>/dev/null || true
        # Clean up legacy HTTP redirect rule if present from older versions
        iptables -t nat -D PREROUTING -i "$BR_IFACE" -p tcp --dport 80 ! -d "$LOCAL_IP" -j DNAT --to-destination "$LOCAL_IP":80 2>/dev/null || true

        # Remove only the Nightwatch MASQUERADE rule (preserve Tailscale NAT)
        INET_IFACE="${INET_IFACE:-wlan0}"
        iptables -t nat -D POSTROUTING -o "$INET_IFACE" -j MASQUERADE 2>/dev/null || true
        iptables -D FORWARD -i "$BR_IFACE" -o "$INET_IFACE" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -i "$INET_IFACE" -o "$BR_IFACE" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

        echo "[+] Mesh network stopped"
        ;;

    status)
        echo "==============================="
        echo "  Nightwatch Mesh Status"
        echo "==============================="
        echo ""
        echo "  Node mode: $NODE_MODE"
        echo ""

        echo "== batman-adv =="
        if [ -d /sys/class/net/"$BAT_IFACE" ]; then
            echo "  Version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'N/A')"
            echo "  Algorithm: $(batctl meshif "$BAT_IFACE" ra 2>/dev/null || batctl ra 2>/dev/null || echo 'N/A')"
            echo "  Gateway mode: $(batctl meshif "$BAT_IFACE" gw_mode 2>/dev/null || batctl gw_mode 2>/dev/null || echo 'N/A')"
        else
            echo "  [!] $BAT_IFACE not found"
        fi

        echo ""
        echo "== Linux Bridge ($BR_IFACE) =="
        if [ -d /sys/class/net/"$BR_IFACE" ]; then
            echo "  IP: $(ip -4 addr show dev "$BR_IFACE" 2>/dev/null | grep inet | awk '{print $2}' || echo 'none')"
            echo "  Ports: $(ls /sys/class/net/"$BR_IFACE"/brif/ 2>/dev/null | tr '\n' ' ' || echo 'none')"
        else
            echo "  [!] $BR_IFACE not found"
        fi

        echo ""
        echo "== dnsmasq (DHCP + captive portal) =="
        DNSMASQ_PID="/var/run/dnsmasq-nightwatch.pid"
        if [ -f "$DNSMASQ_PID" ] && kill -0 "$(cat "$DNSMASQ_PID")" 2>/dev/null; then
            echo "  Status: running (PID $(cat "$DNSMASQ_PID"))"
            LEASES="/var/lib/misc/dnsmasq.leases"
            if [ -f "$LEASES" ]; then
                lease_count=$(wc -l < "$LEASES")
                echo "  Active leases: $lease_count"
            fi
        else
            echo "  [!] dnsmasq not running"
        fi

        echo ""
        echo "== hostapd (WiFi AP) =="
        HOSTAPD_PID="/var/run/hostapd-nightwatch.pid"
        if [ -f "$HOSTAPD_PID" ] && kill -0 "$(cat "$HOSTAPD_PID")" 2>/dev/null; then
            echo "  Status: running (PID $(cat "$HOSTAPD_PID"))"
            echo "  SSID: ${WIFI_SSID}"
            echo "  BSSID: ${AP_BSSID}"
            echo "  Channel: ${AP_CHANNEL}"
            if command -v hostapd_cli >/dev/null 2>&1; then
                CLIENT_COUNT=$(hostapd_cli -i "$AP_IFACE" all_sta 2>/dev/null | grep -c "^[0-9a-f]" || echo "0")
                echo "  Connected clients: $CLIENT_COUNT"
            fi
        else
            echo "  [!] hostapd not running"
        fi

        echo ""
        echo "== 802.11s Mesh ($MESH_IFACE) =="
        if iw dev "$MESH_IFACE" info 2>/dev/null | grep -q mesh; then
            iw dev "$MESH_IFACE" info 2>/dev/null | grep -E "type|channel|txpower" | sed 's/^/  /'
            echo ""
            echo "  Mesh peers:"
            iw dev "$MESH_IFACE" station dump 2>/dev/null | grep -E "Station|signal:|mesh plink:" | sed 's/^/    /' || echo "    (none)"
        else
            echo "  [!] Not in mesh mode"
        fi

        echo ""
        echo "== batman-adv Neighbors =="
        batctl meshif "$BAT_IFACE" n 2>/dev/null || batctl n 2>/dev/null || echo "  (none)"

        echo ""
        echo "== batman-adv Originators (full mesh) =="
        batctl meshif "$BAT_IFACE" o 2>/dev/null || batctl o 2>/dev/null || echo "  (none)"

        echo ""
        echo "== batman-adv Gateways =="
        batctl meshif "$BAT_IFACE" gwl 2>/dev/null || batctl gwl 2>/dev/null || echo "  (none)"

        echo ""
        echo "== Interfaces in batman-adv =="
        batctl meshif "$BAT_IFACE" if 2>/dev/null || batctl if 2>/dev/null || echo "  (none)"
        ;;

    restart-dnsmasq)
        # CdC §3.4 #3a — kill → restart < 60 s. Called by mesh-watchdog when
        # dnsmasq has died but the rest of the mesh is healthy, to avoid a
        # full mesh restart (which would also bounce hostapd and disconnect
        # phones).
        start_dnsmasq
        ;;

    *)
        echo "Usage: $0 {start|stop|status|restart-dnsmasq}"
        exit 1
        ;;
esac
