#!/bin/bash
set -e

# Try multiple possible paths for .env file
ENV_FILE=""
for path in ".env" "../.env" "../../.env"; do
    if [[ -f "$path" ]]; then
        ENV_FILE="$path"
        break
    fi
done

# Load .env if it exists
if [[ -f "$ENV_FILE" ]]; then
  echo "[+] Found .env file at: $ENV_FILE"
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
else
  echo "[-] No .env file found in current directory or parent directories"
fi

# Try to detect IFACE if still not set
IFACE=${IFACE:-$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)}

# Check if wlan1 specifically exists (for mesh mode)
if [[ "$IFACE" == "wlan1" ]] && ! ip link show wlan1 >/dev/null 2>&1; then
    echo "[-] Warning: wlan1 interface not found!"
    echo "[?] wlan1 is required for BATMAN mesh networking."
    echo ""
    echo "Available interfaces:"
    ip link show | grep -E "^[0-9]+:" | grep -v "lo:" | sed 's/^[0-9]*: /  - /'
    echo ""
    read -p "Would you like to continue WITHOUT mesh mode? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "[-] Exiting. Please ensure wlan1 interface is available for mesh mode."
        exit 1
    else
        echo "[!] Continuing in non-mesh mode..."
        echo "[!] Skipping BATMAN mesh setup."
        exit 0
    fi
fi

# Check if the selected interface exists
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo "[-] Error: Interface $IFACE not found!"
    echo ""
    echo "Available interfaces:"
    ip link show | grep -E "^[0-9]+:" | grep -v "lo:" | sed 's/^[0-9]*: /  - /'
    echo ""
    echo "[-] Please check your .env file and set IFACE to a valid wireless interface."
    exit 1
fi

# Defaults
MESH_ID=${MESH_ID:-batmesh}
FREQ=${FREQ:-2412}

echo "[+] Using interface: $IFACE"
echo "[+] MESH_IP from .env: $MESH_IP"
echo "[+] Current working directory: $(pwd)"
echo "[+] ENV_FILE path: $ENV_FILE"

# Clean up any previous batman state
sudo ip link set bat0 down 2>/dev/null || true
sudo ip link delete bat0 type batadv 2>/dev/null || true

# Reset Wi-Fi interface
echo "[+] Resetting interface $IFACE..."
sudo ip link set "$IFACE" down
sudo iw "$IFACE" set type ibss
sudo ip link set "$IFACE" up

# Join mesh if needed
if ! iw dev "$IFACE" info | grep -q "ssid $MESH_ID"; then
  echo "[+] Joining IBSS mesh '$MESH_ID' on $FREQ MHz..."
  sudo iw "$IFACE" ibss join "$MESH_ID" "$FREQ"
else
  echo "[✓] Already joined mesh '$MESH_ID' — skipping join"
fi

# Load batman-adv and attach
sudo modprobe batman-adv
sudo batctl if add "$IFACE"
sudo ip link set bat0 up

# Assign IP - use MESH_IP from .env if set, otherwise random
if [[ -n "$MESH_IP" && "$MESH_IP" != "" ]]; then
  echo "[+] Using configured MESH_IP: $MESH_IP"
  MYIP="$MESH_IP"
else
RAND=$((RANDOM % 240 + 10))
MYIP="192.168.199.$RAND"
  echo "[+] Auto-assigned IP: $MYIP"
fi

sudo ip addr flush dev bat0
sudo ip addr add "$MYIP/24" dev bat0

echo "[✔] Mesh node ready — IP: $MYIP"

# Write/update .env with current IFACE and IP
if [[ -f "$ENV_FILE" ]]; then
  grep -q "^IFACE=" "$ENV_FILE" && sed -i "s/^IFACE=.*/IFACE=$IFACE/" "$ENV_FILE" || echo "IFACE=$IFACE" >> "$ENV_FILE"
  grep -q "^MESH_IP=" "$ENV_FILE" && sed -i "s/^MESH_IP=.*/MESH_IP=$MYIP/" "$ENV_FILE" || echo "MESH_IP=$MYIP" >> "$ENV_FILE"
fi
