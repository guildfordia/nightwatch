#!/bin/bash
# Nightwatch — Prepare an SD card
#
# Run this on your laptop AFTER flashing Raspberry Pi OS Lite with Pi Imager.
# Pi Imager settings:
#   - OS: Raspberry Pi OS Lite (64-bit recommended)
#   - Set hostname (e.g. nightwatch)
#   - Enable SSH (password or key)
#   - Set username/password
#   - Set WiFi (temporary — for first boot internet access to install packages)
#
# Node number is assigned at SD card preparation time (fixed ID).
# If NODE=N is set (or --node N), that number is used.
# Otherwise, the next free number is auto-picked from .node-registry.
#
# Usage:
#   ./scripts/prepare-sdcard.sh <sdcard_path> [options]
#
# Examples (Linux):
#   ./scripts/prepare-sdcard.sh /dev/sdf
#   ./scripts/prepare-sdcard.sh /dev/sdf --gateway
#   ./scripts/prepare-sdcard.sh /run/media/$USER/rootfs
#
# Examples (macOS):
#   ./scripts/prepare-sdcard.sh /dev/disk4
#   ./scripts/prepare-sdcard.sh /dev/disk4 --gateway
#   ./scripts/prepare-sdcard.sh /Volumes/rootfs
#
# What it does:
#   1. Copies the entire project to /opt/nightwatch/ on the SD card
#   2. Saves secrets to .secrets (nodeconfig generates .env on first boot)
#   3. Writes /etc/nightwatch.conf on the SD card
#   4. Installs the firstboot service (runs on first boot — installs everything)
#
# Secrets:
#   The script prompts for passwords and Tailscale auth key, then bakes them
#   into .secrets on the SD card. You can also set them via environment:
#     ROUTER_PASSWORD=xxx IRC_LINK_PASSWORD=yyy TAILSCALE_AUTH_KEY=zzz ./scripts/prepare-sdcard.sh /path/to/rootfs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# ---- Node registry ----
# Tracks assigned node numbers to prevent duplicates across SD cards.
REGISTRY_FILE="$PROJECT_DIR/.node-registry"

registry_init() {
    if [ ! -f "$REGISTRY_FILE" ]; then
        printf '# Nightwatch Node Registry — tracks assigned node numbers\n# NODE  DATE        MODE        NOTES\n' > "$REGISTRY_FILE"
    fi
}

registry_taken_numbers() {
    [ -f "$REGISTRY_FILE" ] || return
    grep -v '^#' "$REGISTRY_FILE" | grep -v '^$' | awk '{print $1}' | sort -n
}

registry_has() {
    local num="$1"
    registry_taken_numbers | grep -qw "$num"
}

registry_next_free() {
    local taken
    taken=$(registry_taken_numbers)
    for i in $(seq 1 "$MAX_NODES"); do
        if ! echo "$taken" | grep -qw "$i"; then
            echo "$i"
            return
        fi
    done
    echo ""
}

registry_add() {
    local num="$1" mode="$2" notes="${3:-}"
    registry_init
    if registry_has "$num"; then
        return 1
    fi
    printf '%-6s  %s  %-12s  %s\n' "$num" "$(date +%Y-%m-%d)" "$mode" "$notes" >> "$REGISTRY_FILE"
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---- Usage ----

usage() {
    echo "Usage: $0 <sdcard_path> [options]"
    echo ""
    echo "  sdcard_path:  Block device (e.g. /dev/sdf) or mounted rootfs path"
    echo ""
    echo "Options:"
    echo "  --node N      Assign node number N (1-$MAX_NODES). Auto-picks if omitted."
    echo "  --mode MODE   Set node mode: mesh (default), gateway, sound-bridge"
    echo "  --gateway     Shorthand for --mode gateway"
    echo "  --yes         Skip confirmation prompts"
    echo ""
    echo "Examples (Linux):"
    echo "  $0 /dev/sdf"
    echo "  $0 /dev/sdf --gateway"
    echo ""
    echo "Examples (macOS):"
    echo "  $0 /dev/disk4"
    echo "  $0 /dev/disk4 --gateway"
    echo "  $0 /Volumes/rootfs"
    echo ""
    echo "Node number is assigned at SD card prep time (tracked in .node-registry)."
    echo "Set NODE=N or --node N, or let the script auto-pick the next free number."
    echo ""
    echo "Environment variables (optional — skips password prompts):"
    echo "  ROUTER_PASSWORD     GL.iNet router admin password"
    echo "  IRC_LINK_PASSWORD   IRC federation password (same on all nodes)"
    echo "  TAILSCALE_AUTH_KEY  Tailscale pre-auth key (from admin console)"
    echo "  HF_TOKEN            Hugging Face API token"
    exit 1
}

GATEWAY_MODE=false
NODE_MODE="mesh"
SD_ROOT=""
AUTO_YES=false
NODE_NUM="${NODE:-}"

# Parse args
while [ $# -gt 0 ]; do
    case "$1" in
        --node)       shift; NODE_NUM="${1:-}" ;;
        --gateway)    NODE_MODE="gateway"; GATEWAY_MODE=true ;;
        --mode)       shift; NODE_MODE="${1:-mesh}" ;;
        --yes|-y)     AUTO_YES=true ;;
        --help|-h)    usage ;;
        *)            SD_ROOT="$1" ;;
    esac
    shift
done

# Validate mode
case "$NODE_MODE" in
    mesh|gateway|sound-bridge) ;;
    *) echo -e "${RED}Error: invalid mode '$NODE_MODE' (valid: mesh, gateway, sound-bridge)${NC}"; exit 1 ;;
esac
GATEWAY_MODE=$( [ "$NODE_MODE" = "gateway" ] && echo true || echo false )

# ---- Validate SD card path ----

if [ -z "$SD_ROOT" ]; then
    echo -e "${RED}Error: SD card path is required${NC}"
    usage
fi

# Detect platform
OS_TYPE="$(uname -s)"

# Rsync exclusions shared by both direct-copy and tarball paths
RSYNC_EXCLUDES=(
    --exclude='.git'
    --exclude='.env'
    --exclude='.secrets'
    --exclude='ngircd/ngircd.conf'
    --exclude='dnsmasq/dnsmasq.conf'
    --exclude='*.log'
    --exclude='*.img'
    --exclude='*.img.xz'
    --exclude='*.img.gz'
    --exclude='*.rpi-imager-manifest'
    --exclude='pishrink.sh'
    --exclude='.DS_Store'
    --exclude='node_modules'
    --exclude='.firstboot-done'
    --exclude='.node-number'
    --exclude='.node-registry'
    --exclude='PiShrink'
)

# ---- macOS boot-partition staging ----
# macOS cannot mount ext4 natively. Instead we stage files on the boot partition
# (FAT32, natively writable) and the Pi unpacks them on first boot.

prepare_via_boot_partition() {
    local disk="$1"
    local boot_part="${disk}s1"

    if [ ! -b "$boot_part" ]; then
        echo -e "${RED}Error: Boot partition $boot_part not found${NC}"
        echo "List partitions with: diskutil list $disk"
        exit 1
    fi

    # Find or mount boot partition
    local boot_mount
    boot_mount=$(diskutil info "$boot_part" 2>/dev/null | awk -F: '/Mount Point/{gsub(/^[ \t]+/,"",$2); print $2}')
    if [ -z "$boot_mount" ]; then
        echo "[+] Mounting boot partition..."
        diskutil mount "$boot_part" >/dev/null 2>&1 || true
        boot_mount=$(diskutil info "$boot_part" 2>/dev/null | awk -F: '/Mount Point/{gsub(/^[ \t]+/,"",$2); print $2}')
    fi

    if [ -z "$boot_mount" ] || [ ! -d "$boot_mount" ]; then
        echo -e "${RED}Error: Could not mount boot partition $boot_part${NC}"
        echo "Try mounting manually: diskutil mount $boot_part"
        exit 1
    fi

    echo "[+] Boot partition: $boot_mount"

    # Sanity check — boot partition should have config.txt or cmdline.txt
    if [ ! -f "$boot_mount/cmdline.txt" ] && [ ! -f "$boot_mount/config.txt" ]; then
        echo -e "${RED}Error: $boot_mount does not look like a Pi boot partition${NC}"
        echo "Expected cmdline.txt or config.txt"
        exit 1
    fi

    echo ""
    echo -e "${BOLD}${CYAN}======================================"
    echo "  Nightwatch SD Card Preparation"
    echo -e "======================================${NC}"
    echo ""
    echo "  Mode:       macOS → boot partition staging"
    echo "  Node:       $NODE_NUM (IP: $MESH_IP)"
    echo "  Gateway:    $GATEWAY_MODE"
    echo "  Tailscale:  $([ -n "${TAILSCALE_AUTH_KEY:-}" ] && echo 'yes (auth key set)' || echo 'no')"
    echo "  Boot part:  $boot_mount"
    echo ""

    if [ "$AUTO_YES" != true ]; then
        echo -e "${YELLOW}Files will be staged on the boot partition (FAT32).${NC}"
        echo -e "${YELLOW}The Pi will unpack them to /opt/nightwatch/ on first boot.${NC}"
        echo ""
        read -rp "Continue? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 0
        fi
    fi

    echo ""

    # Step 1: Create project tarball on boot partition
    echo "[1/5] Creating project tarball on boot partition..."
    local staging_dir
    staging_dir=$(umask 077 && mktemp -d)
    rsync -a "${RSYNC_EXCLUDES[@]}" "$PROJECT_DIR/" "$staging_dir/"

    # Remove any stale .env or .secrets from staging
    rm -f "$staging_dir/.env" "$staging_dir/.secrets"

    tar czf "$boot_mount/nightwatch.tar.gz" -C "$staging_dir" .
    rm -rf "$staging_dir"
    echo "[+] nightwatch.tar.gz written to boot partition"

    # Step 2: Write secrets
    echo "[2/5] Writing secrets to boot partition..."
    local secrets_file="$boot_mount/nightwatch-secrets"
    printf '%s\n' '# Nightwatch secrets — baked by prepare-sdcard.sh' > "$secrets_file"
    printf '%s\n' '# nightwatch-stage.sh copies these on first boot' >> "$secrets_file"
    printf 'ROUTER_PASSWORD=%s\n' "$ROUTER_PASSWORD" >> "$secrets_file"
    printf 'IRC_LINK_PASSWORD=%s\n' "$IRC_LINK_PASSWORD" >> "$secrets_file"
    printf 'TAILSCALE_AUTH_KEY=%s\n' "${TAILSCALE_AUTH_KEY:-}" >> "$secrets_file"
    printf 'HF_TOKEN=%s\n' "${HF_TOKEN:-}" >> "$secrets_file"
    printf 'NODE_MODE=%s\n' "$NODE_MODE" >> "$secrets_file"
    echo "[+] Secrets staged"
    echo "    ROUTER_PASSWORD=***"
    echo "    IRC_LINK_PASSWORD=***"
    echo "    TAILSCALE_AUTH_KEY=$([ -n "${TAILSCALE_AUTH_KEY:-}" ] && echo '***' || echo '(empty)')"
    echo "    HF_TOKEN=$([ -n "${HF_TOKEN:-}" ] && echo '***' || echo '(empty)')"

    # Step 3: Write node ID to boot partition
    echo "[3/5] Writing node ID ($NODE_NUM) to boot partition..."
    printf '%s\n' "$NODE_NUM" > "$boot_mount/nightwatch-node-id"
    echo "[+] nightwatch-node-id written"

    # Step 4: Write staging script (runs on the Pi to unpack from boot → rootfs)
    echo "[4/5] Writing staging script..."
    cat > "$boot_mount/nightwatch-stage.sh" << 'STAGEEOF'
#!/bin/bash
# Nightwatch — Unpack staged files from boot partition to rootfs
# Written by prepare-sdcard.sh (macOS boot-partition staging mode)
# This script runs ONCE on first boot, then cleans up after itself.
# It may be called from firstrun.sh (traditional) or cloud-init runcmd.
set -e

# ---- LED error indicator ----
LED_PATH=""
for _led in /sys/class/leds/ACT /sys/class/leds/led0; do
    [ -d "$_led" ] && LED_PATH="$_led" && break
done

stage_fail() {
    echo "[-] nightwatch-stage FAILED: $1"
    # Fast blink = error (same pattern as firstboot_fail in firstboot.sh)
    if [ -n "$LED_PATH" ]; then
        echo "timer" > "$LED_PATH/trigger" 2>/dev/null || true
        echo 100  > "$LED_PATH/delay_on"  2>/dev/null || true
        echo 100  > "$LED_PATH/delay_off" 2>/dev/null || true
    fi
    exit 1
}

trap 'stage_fail "unexpected error at line $LINENO"' ERR

# Detect boot partition mount (Bookworm: /boot/firmware, older: /boot)
if [ -f /boot/firmware/nightwatch.tar.gz ]; then
    BOOT=/boot/firmware
elif [ -f /boot/nightwatch.tar.gz ]; then
    BOOT=/boot
else
    stage_fail "nightwatch.tar.gz not found on boot partition"
fi

# Log to boot partition (readable on macOS for debugging)
STAGE_LOG="$BOOT/nightwatch-firstboot.log"
exec > >(tee -a "$STAGE_LOG") 2>&1

echo ""
echo "======================================"
echo "  Nightwatch Staging"
echo "  $(date)"
echo "======================================"
echo "[+] nightwatch-stage: unpacking from $BOOT to /opt/nightwatch/"

# Extract project
mkdir -p /opt/nightwatch
tar xzf "$BOOT/nightwatch.tar.gz" -C /opt/nightwatch/

# Copy secrets
if [ -f "$BOOT/nightwatch-secrets" ]; then
    mv "$BOOT/nightwatch-secrets" /opt/nightwatch/.secrets
    chmod 600 /opt/nightwatch/.secrets
fi

# Copy fixed node ID (assigned at SD card prep time)
if [ -f "$BOOT/nightwatch-node-id" ]; then
    NODE_ID=$(cat "$BOOT/nightwatch-node-id")
    printf '%s\nFIXED\n' "$NODE_ID" > /opt/nightwatch/.node-number
    rm -f "$BOOT/nightwatch-node-id"
    echo "[+] nightwatch-stage: node ID set to $NODE_ID (FIXED)"
fi

# Write nightwatch.conf
echo "NIGHTWATCH_DIR=/opt/nightwatch" > /etc/nightwatch.conf

# Make scripts executable
chmod +x /opt/nightwatch/scripts/*.sh 2>/dev/null || true

# Install and enable firstboot service
cp /opt/nightwatch/scripts/nightwatch-firstboot.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable nightwatch-firstboot.service

# ---- WiFi fallback ----
# Cloud-init on Raspberry Pi OS Bookworm cannot translate netplan v2 wifis:
# sections into NetworkManager connections (cc_netplan_nm_patch module missing).
# Parse network-config and create the NM connection file directly.
NM_DIR="/etc/NetworkManager/system-connections"
NETCFG="$BOOT/network-config"
if [ -d "$NM_DIR" ] && [ -f "$NETCFG" ] && grep -q 'wifis:' "$NETCFG"; then
    # Only create if NM has no WiFi connections yet
    if ! ls "$NM_DIR"/*.nmconnection 2>/dev/null | grep -q .; then
        # Extract SSID (first quoted key under access-points:)
        WIFI_SSID=$(grep -A5 'access-points:' "$NETCFG" | sed -n 's/^[[:space:]]*"\([^"]*\)":.*/\1/p' | head -1)
        # Extract password
        WIFI_PSK=$(grep -A10 'access-points:' "$NETCFG" | sed -n 's/^[[:space:]]*password:[[:space:]]*"\?\([^"]*\)"\?[[:space:]]*$/\1/p' | head -1)

        if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PSK" ]; then
            WIFI_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "a1b2c3d4-wifi-0000-0000-$(date +%s)")
            cat > "$NM_DIR/$WIFI_SSID.nmconnection" << NMEOF
[connection]
id=$WIFI_SSID
uuid=$WIFI_UUID
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$WIFI_SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFI_PSK

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
NMEOF
            chmod 600 "$NM_DIR/$WIFI_SSID.nmconnection"
            echo "[+] nightwatch-stage: created NM WiFi connection for '$WIFI_SSID'"
            # Reload NM to pick up the new connection
            nmcli connection reload 2>/dev/null || true
        else
            echo "[!] nightwatch-stage: could not parse WiFi SSID/password from network-config"
        fi
    fi
fi

# Clean up staged files from boot partition
rm -f "$BOOT/nightwatch.tar.gz" "$BOOT/nightwatch-secrets" "$BOOT/nightwatch-node-id" "$BOOT/nightwatch-stage.sh"

# Remove systemd.run from cmdline.txt so the next boot uses normal multi-user.target.
# Without this, systemd.unit=kernel-command-line.target stays in cmdline.txt and
# the Pi boots into a minimal target with no networking or services.
CMDLINE="$BOOT/cmdline.txt"
if [ -f "$CMDLINE" ] && grep -q 'systemd\.run=' "$CMDLINE"; then
    sed -i 's| systemd\.run=[^ ]*||g; s| systemd\.run_success_action=[^ ]*||g; s| systemd\.unit=kernel-command-line\.target||g' "$CMDLINE"
    echo "[+] nightwatch-stage: cleaned systemd.run from cmdline.txt"
fi

# Schedule a reboot so the firstboot service starts.
echo "[+] nightwatch-stage: scheduling reboot for firstboot service"
shutdown -r +1 "Nightwatch: rebooting to start firstboot setup" &

echo "[+] nightwatch-stage: done — firstboot service will run after reboot"
STAGEEOF
    chmod +x "$boot_mount/nightwatch-stage.sh"

    # Step 5: Configure first-boot trigger
    # Newer Pi Imager uses cloud-init (user-data) instead of firstrun.sh.
    # Detect which mechanism is in use and inject accordingly.
    echo "[5/5] Configuring first-boot trigger..."
    local firstrun="$boot_mount/firstrun.sh"
    local userdata="$boot_mount/user-data"
    local cmdline="$boot_mount/cmdline.txt"
    local stage_cmd="/boot/firmware/nightwatch-stage.sh || true"

    if [ -f "$userdata" ] && grep -q '#cloud-config' "$userdata"; then
        # ---- Cloud-init image (newer Pi Imager) ----
        echo "[+] Cloud-init image detected (user-data present)"

        # Inject staging into cloud-init runcmd
        if grep -q 'nightwatch-stage' "$userdata"; then
            echo "[+] Staging command already in user-data"
        else
            if grep -q '^runcmd:' "$userdata"; then
                # Insert our command after the existing runcmd: line
                local tmp_ud
                tmp_ud=$(mktemp)
                local inserted=false
                while IFS= read -r line; do
                    echo "$line" >> "$tmp_ud"
                    if [ "$inserted" = false ] && echo "$line" | grep -q '^runcmd:'; then
                        echo "  - [/boot/firmware/nightwatch-stage.sh]" >> "$tmp_ud"
                        inserted=true
                    fi
                done < "$userdata"
                cp "$tmp_ud" "$userdata"
                rm -f "$tmp_ud"
            else
                printf '\nruncmd:\n  - [/boot/firmware/nightwatch-stage.sh]\n' >> "$userdata"
            fi
            echo "[+] Staging command added to cloud-init user-data"
        fi

        # Replace any existing systemd.run (e.g. Pi Imager's broken firstrun.sh reference)
        # with our staging script. This ensures staging runs even if cloud-init runcmd
        # fails (which happens on some Bookworm images).
        if [ -f "$cmdline" ]; then
            local clean_cmdline
            clean_cmdline=$(tr -d '\n' < "$cmdline" | sed 's| systemd\.run=[^ ]*||g; s| systemd\.run_success_action=[^ ]*||g; s| systemd\.unit=kernel-command-line\.target||g' | sed 's/[[:space:]]*$//')
            printf '%s systemd.run=/boot/firmware/nightwatch-stage.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target\n' \
                "$clean_cmdline" > "$cmdline"
            rm -f "$firstrun" 2>/dev/null
            echo "[+] cmdline.txt: systemd.run set to nightwatch-stage.sh (belt-and-suspenders with cloud-init)"
        fi

    elif [ -f "$firstrun" ]; then
        # ---- Traditional firstrun.sh (older Pi Imager) ----
        if grep -q 'nightwatch-stage' "$firstrun"; then
            echo "[+] Staging call already present in firstrun.sh"
        elif grep -q 'shutdown\|reboot' "$firstrun"; then
            # Insert before the first shutdown/reboot line
            local tmp_firstrun
            tmp_firstrun=$(mktemp)
            local inserted=false
            while IFS= read -r line; do
                if [ "$inserted" = false ] && echo "$line" | grep -q 'shutdown\|reboot'; then
                    echo "" >> "$tmp_firstrun"
                    echo "# Nightwatch: unpack project from boot partition" >> "$tmp_firstrun"
                    echo "$stage_cmd" >> "$tmp_firstrun"
                    echo "" >> "$tmp_firstrun"
                    inserted=true
                fi
                echo "$line" >> "$tmp_firstrun"
            done < "$firstrun"
            cp "$tmp_firstrun" "$firstrun"
            rm -f "$tmp_firstrun"
            echo "[+] Staging call injected into existing firstrun.sh"
        else
            # No shutdown line found — append
            echo "" >> "$firstrun"
            echo "# Nightwatch: unpack project from boot partition" >> "$firstrun"
            echo "$stage_cmd" >> "$firstrun"
            echo "[+] Staging call appended to firstrun.sh"
        fi

    else
        # ---- No firstrun.sh and no cloud-init — create firstrun.sh ----
        cat > "$firstrun" << FIRSTEOF
#!/bin/bash
set +e

# Nightwatch: unpack project from boot partition
$stage_cmd

rm -f /boot/firmware/firstrun.sh
shutdown -r now
exit 0
FIRSTEOF
        chmod +x "$firstrun"

        # Ensure cmdline.txt triggers firstrun.sh on boot
        if [ -f "$cmdline" ] && ! grep -q 'systemd.run=' "$cmdline"; then
            local existing
            existing=$(tr -d '\n' < "$cmdline")
            printf '%s systemd.run=/boot/firmware/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target\n' \
                "$existing" > "$cmdline"
            echo "[+] cmdline.txt updated to trigger firstrun.sh"
        fi

        echo "[+] firstrun.sh created"
    fi

    # Verify
    echo ""
    echo "[+] Verifying boot partition files..."
    local errors=0
    for f in nightwatch.tar.gz nightwatch-secrets nightwatch-node-id nightwatch-stage.sh; do
        if [ ! -f "$boot_mount/$f" ]; then
            echo -e "  ${RED}[MISS] $f${NC}"
            ((errors++)) || true
        fi
    done
    if [ "$errors" -gt 0 ]; then
        echo -e "${RED}Warning: $errors missing files${NC}"
    else
        echo -e "  ${GREEN}All staging files present${NC}"
    fi

    # Done
    echo ""
    echo -e "${GREEN}${BOLD}======================================"
    echo "  SD Card Ready! (boot-partition staging)"
    echo "======================================${NC}"
    echo ""
    echo "  Node:       $NODE_NUM (IP: $MESH_IP)"
    echo "  Gateway:    $GATEWAY_MODE"
    echo "  Tailscale:  $([ -n "${TAILSCALE_AUTH_KEY:-}" ] && echo 'yes' || echo 'no')"
    echo ""
    echo -e "  ${BOLD}How it works on macOS:${NC}"
    echo "  Files are staged on the boot partition (FAT32)."
    echo "  On first boot, the Pi unpacks them to /opt/nightwatch/"
    echo "  and enables the firstboot service (runs on the next reboot)."
    echo ""
    echo -e "  ${BOLD}Next steps:${NC}"
    echo "  1. Eject: diskutil eject $disk"
    echo "  2. Insert into the Raspberry Pi"
    echo "  3. Power on — first boot takes ~10-15 min (needs internet)"
    echo ""
    echo -e "  ${BOLD}Monitor progress (after Pi boots):${NC}"
    echo "     ssh into the Pi, then:"
    echo "     journalctl -f -u nightwatch-firstboot"
    echo "     tail -f /var/log/nightwatch-firstboot.log"
    echo ""
    echo "  After first boot completes, the Pi will:"
    echo "  - Start the mesh network automatically on every boot"
    echo "  - Start app services (IRC, bridge, web UI)"
    echo "  - Broadcast WiFi hotspot '${WIFI_SSID:-Nightwatch}'"
    if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
    echo "  - Be accessible remotely via Tailscale"
    fi
    echo ""

    # Register this node
    registry_add "$NODE_NUM" "$NODE_MODE" || true
    echo -e "  ${GREEN}Node $NODE_NUM registered in .node-registry${NC}"
    echo ""
}

# If given a block device (e.g. /dev/sdf on Linux, /dev/disk4 on macOS), find and mount the rootfs partition
AUTO_MOUNTED=false
BOOT_STAGING=false
if [ -b "$SD_ROOT" ]; then
    DISK="$SD_ROOT"
    echo "[+] Block device detected: $DISK"

    if [ "$OS_TYPE" = "Darwin" ]; then
        # macOS: stage on boot partition (FAT32) — ext4 rootfs is not writable
        BOOT_STAGING=true
    else
        # ---- Linux block device handling ----
        # Find the rootfs partition (largest Linux partition, typically partition 2)
        ROOTFS_PART=""
        for part in "${DISK}"2 "${DISK}p2"; do
            if [ -b "$part" ]; then
                ROOTFS_PART="$part"
                break
            fi
        done

        if [ -z "$ROOTFS_PART" ]; then
            echo -e "${RED}Error: Could not find rootfs partition on $DISK${NC}"
            echo "Expected ${DISK}2 or ${DISK}p2"
            exit 1
        fi

        # Check if already mounted
        EXISTING_MOUNT=$(lsblk -o MOUNTPOINT -nr "$ROOTFS_PART" 2>/dev/null | head -1)
        if [ -n "$EXISTING_MOUNT" ]; then
            SD_ROOT="$EXISTING_MOUNT"
            echo "[+] Already mounted at $SD_ROOT"
        else
            SD_ROOT="/mnt/nightwatch-sdcard"
            sudo mkdir -p "$SD_ROOT"
            echo "[+] Mounting $ROOTFS_PART → $SD_ROOT"
            sudo mount "$ROOTFS_PART" "$SD_ROOT"
            AUTO_MOUNTED=true
        fi
    fi
fi

# Cleanup function to unmount if we mounted it
cleanup() {
    if [ "$AUTO_MOUNTED" = true ]; then
        echo "[+] Unmounting $SD_ROOT..."
        sudo umount "$SD_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Validate SD card root (skip for macOS boot-partition staging)
if [ "$BOOT_STAGING" = false ]; then
    if [ ! -d "$SD_ROOT/etc" ] || [ ! -d "$SD_ROOT/opt" ]; then
        echo -e "${RED}Error: $SD_ROOT does not look like a Linux rootfs${NC}"
        echo "Expected to find $SD_ROOT/etc and $SD_ROOT/opt"
        exit 1
    fi

    if [ ! -d "$SD_ROOT/etc/systemd/system" ]; then
        echo -e "${RED}Error: $SD_ROOT does not have systemd (not a Pi OS image?)${NC}"
        exit 1
    fi
fi

# ---- Load base config ----

ENV_TEMPLATE="$PROJECT_DIR/.env.example"
if [ ! -f "$ENV_TEMPLATE" ]; then
    echo -e "${RED}Error: .env.example not found in project${NC}"
    exit 1
fi

# Save caller-provided secrets BEFORE load_env overwrites them
_SAVE_ROUTER_PASSWORD="${ROUTER_PASSWORD:-}"
_SAVE_IRC_LINK_PASSWORD="${IRC_LINK_PASSWORD:-}"
_SAVE_TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
_SAVE_HF_TOKEN="${HF_TOKEN:-}"

load_env "$ENV_TEMPLATE"

# Restore caller-provided secrets (load_env clobbers them with .env.example defaults)
[ -n "$_SAVE_ROUTER_PASSWORD" ] && ROUTER_PASSWORD="$_SAVE_ROUTER_PASSWORD"
[ -n "$_SAVE_IRC_LINK_PASSWORD" ] && IRC_LINK_PASSWORD="$_SAVE_IRC_LINK_PASSWORD"
[ -n "$_SAVE_TAILSCALE_AUTH_KEY" ] && TAILSCALE_AUTH_KEY="$_SAVE_TAILSCALE_AUTH_KEY"
[ -n "$_SAVE_HF_TOKEN" ] && HF_TOKEN="$_SAVE_HF_TOKEN"


# ---- Resolve node number ----

registry_init

if [ -n "$NODE_NUM" ]; then
    # Explicit node number from --node or NODE env var
    if ! [[ "$NODE_NUM" =~ ^[0-9]+$ ]] || [ "$NODE_NUM" -lt 1 ] || [ "$NODE_NUM" -gt "$MAX_NODES" ]; then
        echo -e "${RED}Error: invalid node number '$NODE_NUM' (must be 1-$MAX_NODES)${NC}"
        exit 1
    fi
    if registry_has "$NODE_NUM"; then
        echo -e "${YELLOW}Warning: node $NODE_NUM is already assigned in .node-registry${NC}"
        echo ""
        echo "Current assignments:"
        cat "$REGISTRY_FILE"
        echo ""
        read -r -p "Re-use node $NODE_NUM anyway? [y/N] " _confirm
        if [[ ! "$_confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            exit 1
        fi
        _NODE_REUSE=true
    fi
else
    # Auto-pick next free number
    NODE_NUM=$(registry_next_free)
    if [ -z "$NODE_NUM" ]; then
        echo -e "${RED}Error: all node numbers (1-$MAX_NODES) are taken${NC}"
        echo "Remove old entries from .node-registry to free up numbers."
        exit 1
    fi
    echo "[+] Auto-assigned node number: $NODE_NUM"
fi

MESH_IP="192.168.199.$((100 + NODE_NUM))"
echo "[+] Node $NODE_NUM — IP will be $MESH_IP"

# ---- Prompt for secrets ----

# Router password
if [ -z "${ROUTER_PASSWORD:-}" ] || [ "$ROUTER_PASSWORD" = "CHANGE_ME_BEFORE_DEPLOY" ]; then
    if [ "$AUTO_YES" = true ]; then
        echo -e "${RED}Error: ROUTER_PASSWORD not set. Provide via environment or run without --yes.${NC}"
        exit 1
    fi
    echo ""
    echo -e "${BOLD}Set passwords for this deployment:${NC}"
    echo -e "${YELLOW}(These are baked into the SD card — same values for all nodes)${NC}"
    echo ""
    read -rsp "  GL.iNet router admin password: " ROUTER_PASSWORD
    echo ""
fi

# IRC link password
if [ -z "${IRC_LINK_PASSWORD:-}" ] || [ "$IRC_LINK_PASSWORD" = "CHANGE_ME_BEFORE_DEPLOY" ]; then
    if [ "$AUTO_YES" = true ]; then
        echo -e "${RED}Error: IRC_LINK_PASSWORD not set. Provide via environment or run without --yes.${NC}"
        exit 1
    fi
    read -rsp "  IRC federation password (same on ALL nodes): " IRC_LINK_PASSWORD
    echo ""
fi

# Tailscale auth key (optional — skip silently with --yes)
if [ -z "${TAILSCALE_AUTH_KEY:-}" ] && [ "$AUTO_YES" != true ]; then
    echo ""
    echo -e "  ${CYAN}Tailscale auth key (optional — enables remote SSH access)${NC}"
    echo -e "  ${CYAN}Generate at: https://login.tailscale.com/admin/settings/keys${NC}"
    echo -e "  ${CYAN}Use a reusable key so multiple Pis can join.${NC}"
    read -rp "  Tailscale auth key (or press Enter to skip): " TAILSCALE_AUTH_KEY
fi
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

# ---- macOS boot-partition staging: branch here ----
if [ "$BOOT_STAGING" = true ]; then
    prepare_via_boot_partition "$DISK"
    exit 0
fi

echo ""
echo -e "${BOLD}${CYAN}======================================"
echo "  Nightwatch SD Card Preparation"
echo -e "======================================${NC}"
echo ""
echo "  Node:       $NODE_NUM (IP: $MESH_IP)"
echo "  Gateway:    $GATEWAY_MODE"
echo "  Tailscale:  $([ -n "${TAILSCALE_AUTH_KEY:-}" ] && echo 'yes (auth key set)' || echo 'no')"
echo "  SD card:    $SD_ROOT"
echo ""

# Confirm
if [ "$AUTO_YES" != true ]; then
    echo -e "${YELLOW}This will write to $SD_ROOT/opt/nightwatch/${NC}"
    read -rp "Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
    fi
fi

echo ""

# ---- Step 1: Copy project ----

echo "[1/6] Copying project to SD card..."
DEST="$SD_ROOT/opt/nightwatch"
sudo mkdir -p "$DEST"

# Copy everything except .git, .env, and generated files
sudo rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$PROJECT_DIR/" "$DEST/"

echo "[+] Project copied to $DEST"

# ---- Step 2: Save secrets ----

echo "[2/6] Saving secrets (nodeconfig generates .env on first boot)..."

SECRETS_DEST="$DEST/.secrets"
# Write secrets using printf to safely handle special characters in passwords
sudo bash -c "printf '%s\n' '# Nightwatch secrets — baked by prepare-sdcard.sh' > '$SECRETS_DEST'"
sudo bash -c "printf '%s\n' '# nodeconfig.sh injects these into .env on first boot' >> '$SECRETS_DEST'"
printf 'ROUTER_PASSWORD=%s\n' "$ROUTER_PASSWORD" | sudo tee -a "$SECRETS_DEST" > /dev/null
printf 'IRC_LINK_PASSWORD=%s\n' "$IRC_LINK_PASSWORD" | sudo tee -a "$SECRETS_DEST" > /dev/null
printf 'TAILSCALE_AUTH_KEY=%s\n' "${TAILSCALE_AUTH_KEY:-}" | sudo tee -a "$SECRETS_DEST" > /dev/null
printf 'HF_TOKEN=%s\n' "${HF_TOKEN:-}" | sudo tee -a "$SECRETS_DEST" > /dev/null
sudo chmod 600 "$SECRETS_DEST"

printf 'NODE_MODE=%s\n' "$NODE_MODE" | sudo tee -a "$SECRETS_DEST" > /dev/null

# Remove any .env so nodeconfig generates a fresh one
sudo rm -f "$DEST/.env"

echo "[+] Secrets saved"
echo "    ROUTER_PASSWORD=***"
echo "    IRC_LINK_PASSWORD=***"
echo "    TAILSCALE_AUTH_KEY=$([ -n "${TAILSCALE_AUTH_KEY:-}" ] && echo '***' || echo '(empty)')"
echo "    HF_TOKEN=$([ -n "${HF_TOKEN:-}" ] && echo '***' || echo '(empty)')"

# ---- Step 3: Write /etc/nightwatch.conf ----

echo "[3/6] Writing nightwatch.conf..."
echo "NIGHTWATCH_DIR=/opt/nightwatch" | sudo tee "$SD_ROOT/etc/nightwatch.conf" > /dev/null
echo "[+] /etc/nightwatch.conf written"

# ---- Step 4: Install firstboot service ----

echo "[4/6] Installing firstboot service..."
sudo chmod +x "$DEST/scripts/firstboot.sh"
sudo chmod +x "$DEST/scripts/mesh-fix.sh"
sudo chmod +x "$DEST/scripts/setup-rpi.sh"
sudo chmod +x "$DEST/scripts/setup-distributed-irc.sh"
sudo chmod +x "$DEST/scripts/nodeconfig.sh"
sudo chmod +x "$DEST/scripts/node-discovery.sh"
sudo chmod +x "$DEST/scripts/common.sh"

# Copy systemd service
sudo cp "$DEST/scripts/nightwatch-firstboot.service" \
    "$SD_ROOT/etc/systemd/system/nightwatch-firstboot.service"

# Enable it (create the symlink manually since systemctl won't work on a mounted FS)
sudo mkdir -p "$SD_ROOT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/nightwatch-firstboot.service \
    "$SD_ROOT/etc/systemd/system/multi-user.target.wants/nightwatch-firstboot.service"

echo "[+] Firstboot service installed and enabled"

# ---- Step 5: Write fixed node ID ----

echo "[5/6] Writing node ID ($NODE_NUM) to SD card..."
printf '%s\nFIXED\n' "$NODE_NUM" | sudo tee "$DEST/.node-number" > /dev/null
echo "[+] .node-number written (FIXED)"

# ---- Step 6: Verify ----

echo "[6/6] Verifying..."

ERRORS=0
for f in .env.example .secrets .node-number scripts/firstboot.sh scripts/mesh-fix.sh scripts/nodeconfig.sh scripts/node-discovery.sh scripts/setup-distributed-irc.sh irc-bridge-go/irc-bridge html/index.html; do
    if [ ! -f "$DEST/$f" ]; then
        echo -e "  ${RED}[MISS] $f${NC}"
        ((ERRORS++))
    fi
done

if [ ! -f "$SD_ROOT/etc/nightwatch.conf" ]; then
    echo -e "  ${RED}[MISS] /etc/nightwatch.conf${NC}"
    ((ERRORS++))
fi

if [ ! -L "$SD_ROOT/etc/systemd/system/multi-user.target.wants/nightwatch-firstboot.service" ]; then
    echo -e "  ${RED}[MISS] firstboot service symlink${NC}"
    ((ERRORS++))
fi

if [ "$ERRORS" -gt 0 ]; then
    echo -e "${RED}Warning: $ERRORS missing files — check the output above${NC}"
else
    echo -e "  ${GREEN}All files present${NC}"
fi

# ---- Done ----

echo ""
echo -e "${GREEN}${BOLD}======================================"
echo "  SD Card Ready!"
echo "======================================${NC}"
echo ""
echo "  Node:       $NODE_NUM (IP: $MESH_IP)"
echo "  Gateway:    $GATEWAY_MODE"
echo "  Tailscale:  $([ -n "${TAILSCALE_AUTH_KEY:-}" ] && echo 'yes' || echo 'no')"
echo ""
echo -e "  ${BOLD}Next steps:${NC}"
echo "  1. Eject the SD card safely"
echo "  2. Insert into the Raspberry Pi"
echo "  3. Power on — first boot setup runs automatically (~10-15 min)"
echo "     It needs internet (WiFi configured in Pi Imager, or Ethernet)"
echo ""
echo -e "  ${BOLD}Monitor progress (after Pi boots):${NC}"
echo "     ssh into the Pi, then:"
echo "     journalctl -f -u nightwatch-firstboot"
echo "     tail -f /var/log/nightwatch-firstboot.log"
echo ""
echo "  After first boot completes, the Pi will:"
echo "  - Start the mesh network automatically on every boot"
echo "  - Start app services (IRC, bridge, web UI)"
echo "  - Broadcast WiFi hotspot '${WIFI_SSID:-Nightwatch}'"
if [ -n "${TAILSCALE_AUTH_KEY:-}" ]; then
echo "  - Be accessible remotely via Tailscale"
fi
echo ""

# Register this node
registry_add "$NODE_NUM" "$NODE_MODE" || true
echo -e "  ${GREEN}Node $NODE_NUM registered in .node-registry${NC}"
echo ""
