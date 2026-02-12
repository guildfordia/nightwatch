# NIGHTWATCH - Decentralized Mesh Chat

![Nightwatch Banner](https://img.shields.io/badge/NIGHTWATCH-Mesh%20Network%20Terminal-blue?style=for-the-badge)

A resilient chat system for off-grid communication using 802.11s + batman-adv mesh networking. Zero infrastructure required — just power and Raspberry Pis.

## Architecture

```
                              802.11s mesh (wlan1, encrypted via SAE)
                             /            |             \
                          [Pi 1]       [Pi 2]         [Pi 3]  ...  [Pi N]
                          bat0          bat0           bat0          bat0
                        /  |  \       /  |  \        /  |  \      /  |  \
                     wlan0 IRC nginx wlan0 IRC nginx wlan0 ...  wlan0 ...
                      AP              AP              AP          AP
                      |               |               |           |
                   clients         clients         clients     clients

    Optional: one node has eth0 → internet (gateway mode for music program)
```

Each Pi runs:
- **wlan1** (USB dongle) — 802.11s mesh with batman-adv for multi-hop routing
- **wlan0** (onboard) — hostapd access point, bridged into bat0
- **bat0** — batman-adv virtual interface, carries all mesh traffic
- **Docker** — ngircd (IRC), irc-bridge (Go WebSocket), nginx (web frontend)

Users connect to any Pi's WiFi hotspot and access the same chat. Traffic routes through the mesh automatically.

## Features

- **802.11s + batman-adv** — real multi-hop mesh routing (not just single-hop ad-hoc)
- **SAE encryption** — optional WPA3-level security on mesh links
- **Automatic peer discovery** — new nodes join the mesh automatically
- **Self-healing** — routes around failed nodes in seconds
- **Gateway support** — one node can share internet to the whole mesh
- **Hostapd AP per node** — every Pi broadcasts a WiFi hotspot for clients
- **Client roaming** — users move between hotspots seamlessly (same Layer 2 domain)
- **Distributed IRC** — linked servers across nodes, messages sync everywhere
- **Terminal-style web UI** — clean, fast, works on any device
- **Scales to 20+ nodes**

## Hardware Requirements

### Per Node
- **Raspberry Pi 4** (recommended) or Pi 3B+
- **USB WiFi dongle** with 802.11s mesh support (AR9271, MT7612U, or RT5370 chipset)
- **MicroSD card** (32GB+ Class 10)
- **Power supply**

### Recommended Dongles
| Dongle | Chipset | Driver | Price | Notes |
|--------|---------|--------|-------|-------|
| Generic AR9271 | AR9271 | ath9k_htc | ~$10 | Cheapest, widely tested |
| ALFA AWUS036ACM | MT7612U | mt76 | ~$35 | Best performance, dual-band |
| Generic RT5370 | RT5370 | rt2800usb | ~$5 | Budget option |

Verify mesh support: `iw list | grep "mesh point"`

### Gateway Node (optional)
- Ethernet connection to internet (for the music program node)

## Quick Start

```bash
# 1. Clone and setup
git clone https://github.com/guildfordia/nightwatch.git
cd nightwatch
chmod +x scripts/*.sh
sudo ./scripts/setup-rpi.sh

# 2. Configure this node
make prepare-env
nano .env    # Set PI_NUMBER, MESH_IP, AP_SSID, etc.

# 3. Setup distributed IRC (if multi-node)
make setup-distributed-irc

# 4. Start everything
make start
```

## Configuration (.env)

Each Pi needs a unique `PI_NUMBER` and `MESH_IP`. Everything else can be identical:

```bash
# Unique per node
PI_NUMBER=1
MESH_IP=192.168.199.101

# Same on all nodes
MESH_ID=nightwatch
FREQ=2412
AP_SSID=Nightwatch
# AP_PASSWORD=optional-wpa2-password
# MESH_SAE_PASSWORD=optional-mesh-encryption

# Gateway node only (the one with internet)
MESH_GATEWAY=true
INET_IFACE=eth0
```

## Management

```bash
make start          # Start mesh + Docker services
make stop           # Stop everything
make restart        # Restart Docker services
make full-restart   # Full restart (mesh + services)

make mesh-status    # batman-adv peers, originators, AP clients, gateways
make mesh-test      # Ping all configured nodes
make monitor        # Live dashboard (refreshes every 5s)
make logs           # Docker service logs

make mesh-install   # Install systemd service (persists across reboots)
```

## How the Mesh Works

1. **802.11s** creates encrypted wireless links between neighboring nodes
2. **batman-adv** (kernel module) builds a Layer 2 mesh on top — handles multi-hop routing, topology discovery, and self-healing
3. **hostapd** runs an access point on each Pi's onboard WiFi
4. The AP is bridged into **bat0**, so client devices are on the same Layer 2 network as the mesh
5. **Docker services** (IRC, bridge, nginx) bind to the host, reachable via bat0's IP
6. A user on any Pi's hotspot can reach any service on any node

## Multi-Node Deployment

| Node | PI_NUMBER | MESH_IP | Role |
|------|-----------|---------|------|
| Node 1 | 1 | 192.168.199.101 | Regular |
| Node 2 | 2 | 192.168.199.102 | Regular |
| Node 3 | 3 | 192.168.199.103 | Regular |
| ... | ... | ... | ... |
| Music Node | N | 192.168.199.1XX | Gateway (MESH_GATEWAY=true) |

1. Flash each Pi with Raspberry Pi OS Lite
2. Run `setup-rpi.sh` on each
3. Set unique `PI_NUMBER` / `MESH_IP` in `.env`
4. `make start` on each node
5. Nodes auto-discover and mesh. Users connect to any hotspot.

## Troubleshooting

```bash
# Check everything
make mesh-status

# batman-adv not loading?
sudo modprobe batman-adv
lsmod | grep batman

# No mesh peers?
iw dev wlan1 info              # Should show "type mesh point"
iw dev wlan1 station dump      # Should show peer stations
sudo batctl n                  # batman-adv neighbors

# No AP clients?
iw dev wlan0 station dump      # Connected clients
journalctl -u nightwatch-mesh  # Service logs

# Docker services not reaching mesh?
# Services bind to 0.0.0.0, accessible via bat0 IP
curl http://$(ip -4 addr show bat0 | grep inet | awk '{print $2}' | cut -d/ -f1)
```

## Security

- **Mesh encryption**: Set `MESH_SAE_PASSWORD` in `.env` for WPA3-level SAE on all mesh links
- **AP encryption**: Set `AP_PASSWORD` for WPA2 on client hotspots
- **Secrets in .env**: File is gitignored, never committed
- **Generated configs**: `ngircd.conf` is gitignored (contains link passwords)
- **Local-only traffic**: All mesh traffic stays on the mesh, never touches internet

## Contributing

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Commit changes
4. Open Pull Request

## License

MIT License — see [LICENSE](LICENSE)

## Support

- [GitHub Issues](https://github.com/guildfordia/nightwatch/issues)
- [GitHub Discussions](https://github.com/guildfordia/nightwatch/discussions)
