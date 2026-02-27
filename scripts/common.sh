#!/bin/bash
# Nightwatch — Shared helper library
#
# Sourced by all scripts that need common patterns:
#   - Docker Compose detection
#   - .env file loading
#   - ngircd.conf base template generation
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/common.sh"

# detect_docker_compose — sets DC to "docker compose" or "docker-compose"
detect_docker_compose() {
    if docker compose version >/dev/null 2>&1; then
        DC="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        DC="docker-compose"
    else
        DC="docker compose"
    fi
}

# load_env <path> — loads .env file with allexport, exits on missing file
load_env() {
    local env_file="$1"
    if [ ! -f "$env_file" ]; then
        echo "[-] Error: $env_file not found"
        exit 1
    fi
    set -o allexport
    # shellcheck source=/dev/null
    source "$env_file"
    set +o allexport
}

# generate_ngircd_base_conf <conf_path> <server_name> <node_num>
# Writes the base ngircd.conf template (Global, Limits, Options, Channel).
# Callers append [Server] peer blocks or comments after this.
generate_ngircd_base_conf() {
    local conf_path="$1"
    local server_name="$2"
    local node_num="$3"

    mkdir -p "$(dirname "$conf_path")"

    cat > "$conf_path" << EOF
[Global]
Name = $server_name
AdminInfo1 = Nightwatch IRC Server - Node $node_num
AdminInfo2 = Mesh Network
AdminEMail = admin@nightwatch.local
Listen = 0.0.0.0
MotdPhrase = Nightwatch mesh node $node_num
ServerUID = abc
ServerGID = abc

[Limits]
MaxConnections = 150
MaxConnectionsIP = 25
MaxJoins = 3
MaxNickLength = 12
PingTimeout = 300
PongTimeout = 60
IdleTimeout = 900
MaxChannelNameLength = 15
MaxTopicLength = 80
MaxAwayLen = 40
MaxListSize = 100

[Options]
RequireAuthPing = no
PAM = no

[Channel]
name = #nightwatch
topic = Nightwatch Chat
modes = +nt
maxusers = 100
EOF
}
