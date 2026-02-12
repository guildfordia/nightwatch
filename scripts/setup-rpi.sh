#!/bin/bash

set -e

echo "[+] Updating system and installing packages..."
sudo apt update && sudo apt install -y \
    docker.io \
    iproute2 \
    iw \
    wireless-tools \
    net-tools \
    curl \
    git \
    fping

echo "[+] Installing Docker Compose (v2)..."
DOCKER_COMPOSE_BIN="/usr/local/bin/docker-compose"
if ! command -v docker-compose &> /dev/null; then
    # Detect architecture
    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64)
            COMPOSE_ARCH="linux-aarch64"
            ;;
        armv7l|armhf)
            COMPOSE_ARCH="linux-armv7"
            ;;
        x86_64)
            COMPOSE_ARCH="linux-x86_64"
            ;;
        *)
            echo "[-] Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac
    COMPOSE_VERSION="v2.24.6"
    echo "[+] Downloading Docker Compose $COMPOSE_VERSION for $COMPOSE_ARCH..."
    sudo curl -SL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-${COMPOSE_ARCH}" -o "$DOCKER_COMPOSE_BIN"
    sudo chmod +x "$DOCKER_COMPOSE_BIN"
    echo "[+] Docker Compose installed."
else
    echo "[+] Docker Compose already installed."
fi

echo "[+] Adding current user to 'docker' group..."
sudo usermod -aG docker "$USER"
echo "[!] You may need to log out and back in (or run 'newgrp docker') for this to take effect."

echo "[+] Raspberry Pi is ready for IBSS mesh networking and Docker Compose!"
