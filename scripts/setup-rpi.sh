#!/bin/bash
# Nightwatch - Raspberry Pi initial setup
# Installs all required packages for 802.11s + batman-adv mesh networking

set -e

echo "[+] Updating system and installing packages..."
sudo apt update && sudo apt install -y \
    docker.io \
    batctl \
    iproute2 \
    iw \
    wireless-tools \
    net-tools \
    hostapd \
    wpasupplicant \
    iptables \
    curl \
    git \
    fping

echo "[+] Installing Docker Compose (v2)..."
DOCKER_COMPOSE_BIN="/usr/local/bin/docker-compose"
if ! command -v docker-compose &> /dev/null; then
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

echo "[+] Loading batman-adv kernel module..."
sudo modprobe batman-adv
if ! grep -q "^batman-adv" /etc/modules 2>/dev/null; then
    echo "batman-adv" | sudo tee -a /etc/modules > /dev/null
fi
echo "[+] batman-adv version: $(cat /sys/module/batman_adv/version 2>/dev/null || echo 'unknown')"

echo "[+] Disabling hostapd system service (we manage it ourselves)..."
sudo systemctl unmask hostapd 2>/dev/null || true
sudo systemctl disable hostapd 2>/dev/null || true
sudo systemctl stop hostapd 2>/dev/null || true

echo "[+] Adding current user to 'docker' group..."
sudo usermod -aG docker "$USER"
echo "[!] You may need to log out and back in (or run 'newgrp docker') for this to take effect."

echo ""
echo "[+] Verifying mesh support on wireless interfaces..."
for iface in $(iw dev 2>/dev/null | grep Interface | awk '{print $2}'); do
    phy=$(iw dev "$iface" info 2>/dev/null | grep wiphy | awk '{print $2}')
    if [ -n "$phy" ]; then
        mesh_support=$(iw phy "phy${phy}" info 2>/dev/null | grep "mesh point" || true)
        if [ -n "$mesh_support" ]; then
            echo "  [+] $iface (phy${phy}): mesh point supported"
        else
            echo "  [!] $iface (phy${phy}): mesh point NOT supported"
        fi
    fi
done

echo ""
echo "[+] Raspberry Pi is ready for Nightwatch!"
echo "    Next steps:"
echo "    1. Run 'make prepare-env' to create .env"
echo "    2. Edit .env with your node settings"
echo "    3. Run 'make start' to launch everything"
