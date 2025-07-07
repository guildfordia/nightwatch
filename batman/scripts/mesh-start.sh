#!/bin/bash

echo "[+] Starting BATMAN node..."
echo "    → IFACE: $IFACE"
echo "    → MESH_IP: $MESH_IP"
echo ""

if [ -z "$MESH_IP" ] || [ -z "$IFACE" ]; then
  echo "[-] MESH_IP or IFACE not set. Exiting."
  exit 1
fi

# Load batman-adv module
echo "[+] Loading batman-adv module..."
modprobe batman-adv

# Clean up any existing bat0 interface
echo "[+] Cleaning up existing bat0 interface..."
ip link set bat0 down 2>/dev/null || true
ip link delete bat0 type batadv 2>/dev/null || true

# Create bat0 interface
echo "[+] Creating bat0 interface..."
batctl if add "$IFACE"
ip link set bat0 up

# Assign IP to bat0
echo "[+] Assigning IP $MESH_IP to bat0..."
ip addr flush dev bat0
ip addr add "$MESH_IP/24" dev bat0

echo "[+] BATMAN interface setup complete"
echo "    → bat0 IP: $MESH_IP"

# Show BATMAN status
echo "[+] BATMAN status:"
ip a show dev bat0
batctl if
batctl n || true
batctl o || true

# Keep container running
echo "[+] BATMAN node is running. Press Ctrl+C to stop."
tail -f /dev/null
