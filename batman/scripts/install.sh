#!/bin/bash

set -e

echo "[+] Detecting OS and installing BATMAN dependencies..."

if [[ "$(uname)" == "Darwin" ]]; then
  echo "Detected macOS. Please install dependencies manually:"
  echo "  brew install docker batctl iproute2 iw wireless-tools net-tools"
  exit 0

elif [[ "$(uname)" == "Linux" ]]; then
  if [[ -f /etc/arch-release ]]; then
    echo "Detected Arch Linux"
    sudo pacman -Syu --noconfirm
    sudo pacman -S --noconfirm docker batctl iproute2 iw wireless_tools net-tools

  elif [[ -f /etc/debian_version ]]; then
    echo "Detected Debian-based Linux"
    sudo apt-get update
    sudo apt-get install -y docker.io batctl iproute2 iw wireless-tools net-tools

  else
    echo "Unsupported Linux distribution. Please install manually."
    exit 1
  fi
else
  echo "Unsupported OS"
  exit 1
fi

echo "[+] Installing complete."
