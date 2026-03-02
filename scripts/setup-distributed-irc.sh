#!/bin/bash
# Nightwatch — Generate initial ngircd configuration
#
# Creates ngircd.conf for this node with no peer links.
# The discovery daemon (node-discovery.sh) will add peers dynamically
# as other nodes are discovered on the mesh.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ENV_FILE="$PROJECT_DIR/.env"

echo "[+] Setting up IRC configuration..."

load_env "$ENV_FILE"

if [ -z "$PI_NUMBER" ]; then
    echo "[-] Error: PI_NUMBER not set in $ENV_FILE"
    exit 1
fi

if [ -z "$MESH_IP" ]; then
    echo "[-] Error: MESH_IP not set in $ENV_FILE"
    exit 1
fi

SERVER_NAME="node${PI_NUMBER}.nightwatch.irc"
IRC_LINK_PASSWORD="${IRC_LINK_PASSWORD:-nightwatch-mesh-link}"

echo "[+] Configuration:"
echo "    → Node: $PI_NUMBER"
echo "    → Server: $SERVER_NAME"
echo "    → Mesh IP: $MESH_IP"

generate_ngircd_base_conf "$PROJECT_DIR/ngircd/ngircd.conf" "$SERVER_NAME" "$PI_NUMBER"

cat >> "$PROJECT_DIR/ngircd/ngircd.conf" << 'EOF'

# Peer links are added automatically by the discovery daemon.
# Run: scripts/node-discovery.sh peers  — to see discovered nodes.
EOF

echo "[+] ngircd.conf generated (no peers yet — discovery daemon will add them)"
echo "[+] Start discovery: systemctl start nightwatch-discovery"
