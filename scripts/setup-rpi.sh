#!/bin/bash

echo "[+] Updating system and installing packages..."
sudo apt update && sudo apt install -y \
    docker.io \
    batctl \
    iproute2 \
    iw \
    wireless-tools \
    net-tools \
    curl \
    git

echo "[+] Installing Docker Compose (v2)..."
DOCKER_COMPOSE_BIN="/usr/local/bin/docker-compose"
if ! command -v docker-compose &> /dev/null; then
    sudo curl -SL https://github.com/docker/compose/releases/download/v2.24.6/docker-compose-linux-armv7 -o $DOCKER_COMPOSE_BIN
    sudo chmod +x $DOCKER_COMPOSE_BIN
    echo "[+] Docker Compose installed."
else
    echo "[✓] Docker Compose already installed."
fi

echo "[+] Enabling BATMAN kernel module..."
sudo modprobe batman-adv
echo "batman-adv" | sudo tee -a /etc/modules > /dev/null

echo "[+] Adding current user to 'docker' group..."
sudo usermod -aG docker $USER
echo "[!] You may need to log out and back in (or run 'newgrp docker') for this to take effect."

echo "[✓] Raspberry Pi is ready for BATMAN mesh and Docker Compose projects!"
