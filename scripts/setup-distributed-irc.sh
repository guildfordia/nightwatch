#!/bin/bash

# Setup distributed IRC servers for mesh network
# This script reads .env configuration and generates ngircd config

set -e

ENV_FILE=".env"

echo "[+] Setting up distributed IRC configuration..."

# Load environment variables
if [ ! -f "$ENV_FILE" ]; then
    echo "[-] Error: $ENV_FILE not found!"
    echo "[-] Please copy .env.example to .env and configure it first."
    exit 1
fi

# Source the environment file
set -o allexport
source "$ENV_FILE"
set +o allexport

# Validate required variables
if [ -z "$PI_NUMBER" ]; then
    echo "[-] Error: PI_NUMBER not set in $ENV_FILE"
    exit 1
fi

if [ -z "$MESH_IP" ]; then
    echo "[-] Error: MESH_IP not set in $ENV_FILE"
    exit 1
fi

if [ "$DISTRIBUTED_IRC" != "true" ]; then
    echo "[-] Error: DISTRIBUTED_IRC must be set to 'true' in $ENV_FILE"
    exit 1
fi

echo "[+] Configuration loaded:"
echo "    → Pi Number: $PI_NUMBER"
echo "    → Mesh IP: $MESH_IP"
echo "    → IRC Link Password: $IRC_LINK_PASSWORD"

# Get server name for this Pi
case $PI_NUMBER in
    1) SERVER_NAME="$PI1_SERVER_NAME" ;;
    2) SERVER_NAME="$PI2_SERVER_NAME" ;;
    3) SERVER_NAME="$PI3_SERVER_NAME" ;;
    4) SERVER_NAME="$PI4_SERVER_NAME" ;;
    *) echo "[-] Error: Invalid PI_NUMBER: $PI_NUMBER (must be 1-4)"; exit 1 ;;
esac

echo "    → Server Name: $SERVER_NAME"

# Create ngircd configuration
echo "[+] Generating ngircd configuration..."

cat > "ngircd/ngircd.conf" << EOF
[Global]
Name = $SERVER_NAME
AdminInfo1 = Nightwatch IRC Server - Pi $PI_NUMBER
AdminInfo2 = Anywhere On Earth
AdminEMail = rum@xpec.net
Listen = 0.0.0.0
MotdPhrase = Nightwatch - Max 100 users
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
topic = Nightwatch Chat [Max 100 users]
modes = +nt
maxusers = 100

# Server linking configuration for mesh network
# This Pi will connect to other Pis through the mesh network
EOF

# Add server configurations for all other Pis (excluding self)
# Only add entries where both SERVER_NAME and MESH_IP are defined
add_server_link() {
    local pi_num="$1"
    local server_name="$2"
    local mesh_ip="$3"

    # Skip self
    if [ "$PI_NUMBER" = "$pi_num" ]; then
        return
    fi

    # Skip if server name or IP not configured
    if [ -z "$server_name" ] || [ -z "$mesh_ip" ]; then
        echo "    [skip] Pi $pi_num not configured (missing SERVER_NAME or MESH_IP)"
        return
    fi

    cat >> "ngircd/ngircd.conf" << EOF

[Server]
Name = $server_name
Host = $mesh_ip
Port = 6667
MyPassword = $IRC_LINK_PASSWORD
PeerPassword = $IRC_LINK_PASSWORD
Group = 1
Passive = no
EOF
    echo "    [+] Added link to Pi $pi_num ($server_name @ $mesh_ip)"
}

add_server_link 1 "$PI1_SERVER_NAME" "$PI1_MESH_IP"
add_server_link 2 "$PI2_SERVER_NAME" "$PI2_MESH_IP"
add_server_link 3 "$PI3_SERVER_NAME" "$PI3_MESH_IP"
add_server_link 4 "${PI4_SERVER_NAME:-}" "${PI4_MESH_IP:-}"

echo "[+] Generated ngircd configuration for Pi $PI_NUMBER"
echo "[+] Configuration saved to: ngircd/ngircd.conf"

# Show which servers this Pi will connect to
echo "[+] This Pi will connect to:"
if [ "$PI_NUMBER" != "1" ] && [ -n "$PI1_SERVER_NAME" ]; then echo "    -> $PI1_SERVER_NAME ($PI1_MESH_IP)"; fi
if [ "$PI_NUMBER" != "2" ] && [ -n "$PI2_SERVER_NAME" ]; then echo "    -> $PI2_SERVER_NAME ($PI2_MESH_IP)"; fi
if [ "$PI_NUMBER" != "3" ] && [ -n "$PI3_SERVER_NAME" ]; then echo "    -> $PI3_SERVER_NAME ($PI3_MESH_IP)"; fi
if [ "$PI_NUMBER" != "4" ] && [ -n "${PI4_SERVER_NAME:-}" ]; then echo "    -> $PI4_SERVER_NAME ($PI4_MESH_IP)"; fi

echo ""
echo "[+] Next steps:"
echo "    1. Restart the IRC services: docker-compose restart ngircd"
echo "    2. Check IRC server logs: docker-compose logs ngircd"
echo "    3. Test connectivity between servers"
echo ""
echo "[+] To test IRC connectivity:"
echo "    → Connect to localhost:6667 or $MESH_IP:6667"
echo "    → Join channel: #nightwatch"
echo "    → Messages should sync across all Pis" 