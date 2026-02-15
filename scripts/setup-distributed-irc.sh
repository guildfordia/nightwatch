#!/bin/bash
# Nightwatch — Generate initial ngircd configuration
#
# Creates ngircd.conf for this node with no peer links.
# The discovery daemon (node-discovery.sh) will add peers dynamically
# as other nodes are discovered on the mesh.

set -e

ENV_FILE=".env"

echo "[+] Setting up IRC configuration..."

# Load environment variables
if [ ! -f "$ENV_FILE" ]; then
    echo "[-] Error: $ENV_FILE not found!"
    echo "[-] Please copy .env.example to .env and configure it first."
    exit 1
fi

set -o allexport
# shellcheck source=/dev/null
source "$ENV_FILE"
set +o allexport

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

mkdir -p ngircd

cat > "ngircd/ngircd.conf" << EOF
[Global]
Name = $SERVER_NAME
AdminInfo1 = Nightwatch IRC Server - Node $PI_NUMBER
AdminInfo2 = Mesh Network
AdminEMail = admin@nightwatch.local
Listen = 0.0.0.0
MotdPhrase = Nightwatch mesh node $PI_NUMBER
ServerUID = abc
ServerGID = abc
MaxConnections = 150
MaxConnectionsIP = 25
MaxJoins = 3
MaxNickLength = 12
PingTimeout = 300
PongTimeout = 60
IdleTimeout = 900

[Options]
RequireAuthPing = no
PAM = no
Bind = 0.0.0.0
Port = 6667
MaxChannels = 1
MaxListSize = 100

[Limits]
MaxNickLength = 12
MaxChannelNameLength = 15
MaxTopicLength = 80
MaxAwayLen = 40

[Channel]
name = #nightwatch
topic = Nightwatch Chat
modes = +nt
maxusers = 100

# Peer links are added automatically by the discovery daemon.
# Run: scripts/node-discovery.sh peers  — to see discovered nodes.
EOF

echo "[+] ngircd.conf generated (no peers yet — discovery daemon will add them)"
echo "[+] Start discovery: systemctl start nightwatch-discovery"
