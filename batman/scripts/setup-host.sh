#!/bin/bash

set -e

# Get default Wi-Fi interface
# IFACE=${IFACE:-$(iw dev | awk '$1=="Interface"{print $2}' | head -n1)}

# Read MAC
MAC=$(cat /sys/class/net/$IFACE/address)
OCTET1=$(echo $MAC | cut -d: -f5)
RAW_SUFFIX=$((0x$OCTET1))

# Try to find an unused IP in the mesh range
pick_unused_ip() {
  for i in $(seq 0 10); do
    LAST_OCTET=$(( (RAW_SUFFIX + RANDOM + i) % 245 + 10 ))
    IP="192.168.199.$LAST_OCTET"
    if ! ping -c1 -W1 $IP >/dev/null 2>&1; then
      echo $IP
      return 0
    fi
  done
  echo "[-] Could not find unused IP" >&2
  exit 1
}

MESH_IP=$(pick_unused_ip)

echo "[+] Interface: $IFACE"
echo "[+] MAC: $MAC"
echo "[+] Auto-assigned, free IP: $MESH_IP"

# ✅ Exported inline for run.sh
MESH_IP=$MESH_IP IFACE=$IFACE ./scripts/run.sh
