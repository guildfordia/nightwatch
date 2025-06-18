#!/bin/bash

echo "[+] Starting BATMAN node..."
echo "    → IFACE: $IFACE"
echo "    → MESH_IP: $MESH_IP"
echo ""

if [ -z "$MESH_IP" ] || [ -z "$IFACE" ]; then
  echo "[-] MESH_IP or IFACE not set. Exiting."
  exit 1
fi

# Just show info, assume bat0 is already up from host
ip a show dev bat0 || echo "[-] bat0 not found"
batctl if || true
batctl n || true
batctl o || true

tail -f /dev/null
