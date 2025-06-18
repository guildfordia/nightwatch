#!/bin/bash
set -e

ENV_FILE="../.env"

# Load .env if it exists
if [[ -f "$ENV_FILE" ]]; then
  export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

# Try to detect IFACE if still not set
IFACE=${IFACE:-$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)}

# Defaults
MESH_ID=${MESH_ID:-batmesh}
FREQ=${FREQ:-2412}

echo "[+] Using interface: $IFACE"

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

# Assign IP
RAND=$((RANDOM % 240 + 10))
MYIP="192.168.199.$RAND"
sudo ip addr flush dev bat0
sudo ip addr add "$MYIP/24" dev bat0

echo "[✔] Mesh node ready — IP: $MYIP"

# Write/update .env with current IFACE and IP
if [[ -f "$ENV_FILE" ]]; then
  grep -q "^IFACE=" "$ENV_FILE" && sed -i "s/^IFACE=.*/IFACE=$IFACE/" "$ENV_FILE" || echo "IFACE=$IFACE" >> "$ENV_FILE"
  grep -q "^MESH_IP=" "$ENV_FILE" && sed -i "s/^MESH_IP=.*/MESH_IP=$MYIP/" "$ENV_FILE" || echo "MESH_IP=$MYIP" >> "$ENV_FILE"
fi
