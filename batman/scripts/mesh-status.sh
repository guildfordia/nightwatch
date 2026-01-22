#!/bin/bash
set -euo pipefail

echo "[+] Mesh status (read-only)"
command -v batctl >/dev/null || { echo "batctl missing"; exit 1; }

echo "== ip -br a show bat0 =="
ip -br a show bat0 || true

echo "== batctl if =="
batctl if || true

echo "== batctl n (neighbors) =="
batctl n || true

echo "== batctl o (originators) =="
batctl o || true

echo "== iw dev wlan1 info =="
iw dev wlan1 info || true

echo "== iw dev wlan1 link =="
iw dev wlan1 link || true

# stay up if you want to `docker logs -f`
tail -f /dev/null
