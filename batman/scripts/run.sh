#!/bin/bash

set -e

ENV_FILE="../.env"
CONTAINER_NAME="batman-node"
IMAGE_NAME="batman-node"

# Load env from file
if [ -f "$ENV_FILE" ]; then
  echo "[+] Loading config from $ENV_FILE"
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
else
  echo "[-] $ENV_FILE not found. Aborting."
  exit 1
fi

# Validate required values
if [ -z "$MESH_IP" ] || [ -z "$IFACE" ]; then
  echo "[-] MESH_IP or IFACE is not set in $ENV_FILE. Aborting."
  exit 1
fi

MESH_ID="${MESH_ID:-batmesh}"
FREQ="${FREQ:-2412}"

echo "[+] Starting BATMAN container:"
echo "    → IFACE    = $IFACE"
echo "    → MESH_IP  = $MESH_IP"
echo "    → MESH_ID  = $MESH_ID"
echo "    → FREQ     = $FREQ MHz"

# Clean any previous container
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Launch container
docker run -d \
  --name "$CONTAINER_NAME" \
  --privileged \
  --net=host \
  -e MESH_IP="$MESH_IP" \
  -e IFACE="$IFACE" \
  -e MESH_ID="$MESH_ID" \
  -e FREQ="$FREQ" \
  "$IMAGE_NAME"

echo "[✔] BATMAN container '$CONTAINER_NAME' is now running"
