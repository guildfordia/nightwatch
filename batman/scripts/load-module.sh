#!/bin/bash

echo "[+] Loading batman-adv kernel module..."
sudo modprobe batman-adv || echo "batman-adv already loaded"

if ! grep -qxF 'batman-adv' /etc/modules; then
  echo "batman-adv" | sudo tee -a /etc/modules >/dev/null
  echo "[+] Persisted batman-adv in /etc/modules"
else
  echo "[+] batman-adv already persisted"
fi
