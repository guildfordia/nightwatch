# NIGHTWATCH - Decentralized Mesh Chat

![Nightwatch Banner](https://img.shields.io/badge/NIGHTWATCH-Mesh%20Network%20Terminal-blue?style=for-the-badge)

A resilient chat system for off-grid communication using 802.11s + batman-adv mesh networking. Zero infrastructure required — just power, Raspberry Pis, and cheap travel routers.

## Architecture

```
                           802.11s mesh (wlan1, USB dongle)
                          /            |             \
                       [Pi 1]       [Pi 2]         [Pi 3]  ...  [Pi N]
                        bat0          bat0           bat0          bat0
                         |             |              |             |
                        br0           br0            br0           br0
                       / | \         / | \          / | \         / | \
                    eth0 IRC nginx eth0 IRC nginx eth0 ...     eth0 ...
                     |               |              |             |
                  GL.iNet         GL.iNet        GL.iNet       GL.iNet
                  router          router         router        router
                  (WiFi AP)       (WiFi AP)      (WiFi AP)     (WiFi AP)
                     |               |              |             |
                  clients         clients        clients       clients

   Optional: one node has wlan0 → internet (gateway mode)
```

Each Pi runs:
- **wlan1** (USB dongle) — 802.11s mesh with batman-adv for multi-hop routing
- **bat0** — batman-adv virtual interface, carries all mesh traffic
- **br0** — Linux bridge joining bat0 + eth0, holds the mesh IP
- **eth0** — connected to GL.iNet router (dumb AP mode) for client WiFi
- **wlan0** (onboard) — reserved for internet/Tailscale (not used by mesh)
- **Docker** — ngircd (IRC), irc-bridge (Go WebSocket), nginx (web frontend)

Users connect to any router's WiFi and access the same chat. Traffic routes through the mesh automatically via batman-adv.

### Node Discovery & IRC Federation

Nodes find each other automatically:
1. **Discovery daemon** broadcasts UDP beacons on bat0 every 30s
2. When a new peer is found, `ngircd.conf` is regenerated with `[Server]` link blocks
3. ngircd reloads — IRC servers federate and `#nightwatch` syncs across all nodes
4. Peers that stop beaconing expire after 90s and are removed

Federation requires `IRC_LINK_PASSWORD` to match on **all nodes**.

### Dynamic Node Assignment

Nodes auto-configure on first boot — no manual setup needed:
1. **nodeconfig.sh** runs before all other services
2. It temporarily brings up the mesh and scans for existing nodes (192.168.199.101-120)
3. Picks the lowest available node number, sets hostname to `nightwatch-N`
4. Generates `.env` with the correct `PI_NUMBER` and `MESH_IP`
5. Saves the number to `.node-number` so it persists across reboots

## Features

- **802.11s + batman-adv** — real multi-hop mesh routing (not just single-hop ad-hoc)
- **Dynamic node assignment** — flash and boot, no configuration needed
- **SAE encryption** — optional WPA3-level security on mesh links
- **Automatic peer discovery** — UDP broadcast, no manual config
- **IRC federation** — linked servers across nodes, messages sync everywhere
- **Self-healing** — routes around failed nodes in seconds
- **Gateway support** — one node can share internet to the whole mesh
- **GL.iNet router per node** — cheap travel router as WiFi AP (no hostapd needed)
- **Linux bridge (br0)** — bat0 + eth0 bridged so router clients reach the mesh
- **dnsmasq DHCP** — Pi serves DHCP to WiFi clients on br0
- **Client roaming** — users move between routers seamlessly (same Layer 2 domain)
- **Terminal-style web UI** — clean, fast, works on any device
- **Integration test suite** — `make test` verifies mesh, services, and cross-node IRC
- **Golden image cloning** — set up one Pi, clone to all others
- **Scales to 20 nodes**

## Hardware Requirements

### Per Node
- **Raspberry Pi 4/5** (recommended), Pi 3B+, or **Pi Zero 2 W**
- **USB WiFi dongle** with 802.11s mesh support (AR9271, MT7612U, or RT5370 chipset)
- **GL.iNet GL-MT300N-V2** travel router (or similar, connected via ethernet)
- **MicroSD card** (32GB+ Class 10)
- **Power supply** (5V/3A for Pi 4/5, 5V/1.2A minimum for Zero 2 W)

### Recommended Dongles
| Dongle | Chipset | Driver | Price | Notes |
|--------|---------|--------|-------|-------|
| Generic AR9271 | AR9271 | ath9k_htc | ~$10 | Cheapest, widely tested |
| ALFA AWUS036ACM | MT7612U | mt76 | ~$35 | Best performance, dual-band |
| Generic RT5370 | RT5370 | rt2800usb | ~$5 | Budget option |

Verify mesh support: `iw phy phy1 info | grep "mesh point"` (check phy for wlan1, not wlan0)

### Gateway Node (optional)
- Internet connection via wlan0 or ethernet (for the gateway node)

## Deployment

### Prerequisites (laptop)

`make sdcard` works on both **Linux** and **macOS**. It auto-detects your platform.

| Requirement | Linux | macOS |
|-------------|-------|-------|
| **Raspberry Pi Imager** | Yes | Yes |
| **Go** (optional — cross-compiles irc-bridge) | `apt install golang` | `brew install go` |
| **rsync** | Pre-installed | Pre-installed |

> **macOS note:** The Pi rootfs uses ext4, which macOS can't mount. `make sdcard` automatically stages files on the boot partition (FAT32) instead — the Pi unpacks them on first boot. No FUSE or extra tools needed.

### Option A: Golden Image (recommended for multiple Pis)

Set up one Pi fully, then clone it to all others. Clones auto-configure on boot.

**First Pi (one-time setup):**

```bash
# 1. Flash Raspberry Pi OS Lite with Pi Imager (set hostname, SSH, WiFi)
# 2. Keep SD card mounted and prepare it:

# Linux:
make sdcard SD=/dev/sdX

# macOS:
make sdcard SD=/dev/diskN

# 3. Insert SD card in Pi, boot, wait ~10-15 min for firstboot to complete
# 4. SSH in and verify:
ssh user@<pi-ip>
sudo make -C /opt/nightwatch test

# 5. Build the golden image:
sudo make -C /opt/nightwatch image
sudo shutdown -h now
```

**Capture and clone (on your laptop):**

**1. Copy the SD card to an image file:**

```bash
# Linux:
lsblk                            # Find the SD card (e.g. /dev/sdf)
sudo dd if=/dev/sdf of=nightwatch.img bs=4M status=progress

# macOS (use rdisk for ~10x faster reads):
diskutil list                    # Find the SD card (e.g. /dev/disk4)
sudo dd if=/dev/rdisk4 of=nightwatch.img bs=4m status=progress
```

**2. Shrink with [PiShrink](https://github.com/Drewsif/PiShrink)** (30GB → ~6GB):

```bash
# Linux:
sudo bash pishrink.sh nightwatch.img

# macOS (PiShrink needs Linux, so run it in Docker):
sudo chmod 666 nightwatch.img
docker run --rm --privileged -v $(pwd):/workdir ubuntu:latest bash -c \
  "apt-get update && apt-get install -y parted e2fsprogs && \
   cp /workdir/nightwatch.img /tmp/nightwatch.img && \
   bash /workdir/pishrink.sh /tmp/nightwatch.img && \
   cat /tmp/nightwatch.img > /workdir/nightwatch.img"
```

**3. Compress:**

```bash
xz -9 -T0 nightwatch.img        # Creates nightwatch.img.xz (~60-70% smaller)
```

**4. Flash to other SD cards with Raspberry Pi Imager:**
- Choose OS → Use custom → select `nightwatch.img.xz`
- Choose storage → Flash
- No configuration needed — each Pi auto-assigns its node number.

### Option B: Manual Setup (single Pi or development)

```bash
# 1. Clone on the Pi
git clone https://github.com/guildfordia/nightwatch.git
cd nightwatch

# 2. Install (installs packages, configures mesh, sets up router, builds Docker images)
make install

# 3. Start mesh + services
make run

# 4. Verify everything works
make test
```

## Configuration (.env)

Auto-generated by nodeconfig on first boot. Each Pi gets a unique `PI_NUMBER` and `MESH_IP`:

```bash
# ── Node Identity (auto-assigned) ──
PI_NUMBER=1
MESH_IP=192.168.199.101

# ── Mesh Network ──
MESH_IFACE=wlan1
MESH_ID=nightwatch
FREQ=2412
# MESH_SAE_PASSWORD=your-mesh-secret    # Optional: WPA3 mesh encryption

# ── Client Access (GL.iNet router on eth0) ──
AP_IFACE=eth0

# ── Gateway (set on the node with internet) ──
MESH_GATEWAY=false
# INET_IFACE=wlan0

# ── GL.iNet Router ──
ROUTER_IP=192.168.8.1
ROUTER_CONFIGURED_IP=192.168.8.100
ROUTER_PASSWORD=<set-during-install>
WIFI_SSID=Nightwatch
WIFI_PASSWORD=Nightwatch

# ── Docker Services ──
IRC_PORT=6667
BRIDGE_PORT=8080
NGINX_PORT=80
DOCKER_NETWORK=nightwatch-net

# ── IRC Federation ──
# Must be IDENTICAL on all nodes for server linking to work
IRC_LINK_PASSWORD=<set-during-install>
```

## Management

```bash
make install     # First-time setup (run once per Pi)
make run         # Start mesh + Docker services
make stop        # Stop everything
make test        # Full integration test (mesh, Docker, IRC cross-node)
make update      # Pull latest code, rebuild, restart
make status      # Show mesh and service status
make logs        # Follow Docker logs
make clean       # Remove containers and volumes
make monitor     # Live dashboard (refreshes every 5s)
make blink       # Blink onboard LED to identify this Pi
make sdcard      # Prepare SD card for a new node (run on laptop, Linux/macOS)
make build-bridge # Cross-compile irc-bridge for ARM64 (run on laptop, auto in sdcard)
make image       # Prepare this Pi for golden image capture
make router      # Configure GL.iNet router (retry if skipped during install)
make info        # Print detailed node information
```

## How the Mesh Works

1. **802.11s** creates wireless links between neighboring nodes (wlan1, USB dongle)
2. **batman-adv** (kernel module) builds a Layer 2 mesh on top — handles multi-hop routing, topology discovery, and self-healing
3. **br0** (Linux bridge) joins bat0 + eth0, giving them a shared IP (192.168.199.10X)
4. **GL.iNet router** on eth0 acts as a dumb WiFi AP — clients connect to it and land on br0
5. **dnsmasq** on the Pi serves DHCP to clients on br0
6. **Docker services** (IRC, bridge, nginx) bind to 0.0.0.0, reachable via br0's IP
7. **Node discovery** broadcasts on bat0, auto-configures ngircd federation
8. A user on any router's WiFi can reach any service on any node

## Multi-Node Deployment

Node numbers and IPs are assigned automatically on first boot:

| Node | PI_NUMBER | MESH_IP | Role |
|------|-----------|---------|------|
| Node 1 | 1 | 192.168.199.101 | Regular |
| Node 2 | 2 | 192.168.199.102 | Regular |
| Node 3 | 3 | 192.168.199.103 | Gateway (MESH_GATEWAY=true) |
| ... | ... | ... | ... |

**Using golden image (recommended):**
1. Flash `nightwatch.img.xz` to each SD card with Pi Imager
2. Boot each Pi — it auto-assigns a unique node number
3. Nodes discover each other and form the mesh automatically

**Manual setup:**
1. Run `make install` on each Pi
2. Ensure `IRC_LINK_PASSWORD` is the **same** on all nodes
3. `make run` on each node
4. Nodes auto-discover and mesh. Users connect to any router's WiFi.

## Troubleshooting

```bash
# Full integration test
make test

# Quick status
make status

# batman-adv not loading?
sudo modprobe batman-adv
lsmod | grep batman

# No mesh peers?
iw dev wlan1 info              # Should show "type mesh point"
iw dev wlan1 station dump      # Should show peer stations
sudo batctl meshif bat0 n      # batman-adv neighbors

# br0 bridge issues?
bridge link show               # Should show bat0 and eth0
ip addr show br0               # Should have 192.168.199.10X

# IRC federation broken?
docker logs ngircd 2>&1 | grep -i "bad password\|server\|link"
# If "Bad password" → IRC_LINK_PASSWORD doesn't match between nodes

# No clients getting DHCP?
sudo systemctl status dnsmasq
cat /var/lib/misc/dnsmasq.leases

# Docker services not reachable?
docker ps                      # All 3 should be healthy
curl http://localhost/          # Nginx
curl http://localhost:8080/health  # Bridge
nc -z localhost 6667           # IRC

# Firstboot failed?
sudo cat /var/log/nightwatch-firstboot.log
sudo rm -f /opt/nightwatch/.firstboot-done
sudo /opt/nightwatch/scripts/firstboot.sh
```

## FAQ

### I can't SSH to `nightwatch-N.local` after first boot

The Pi needs ~2 minutes to complete the first boot cycle: nodeconfig waits 60s for mesh convergence, then assigns a node number and sets the hostname. Wait 2-3 minutes after powering on, then try `ping nightwatch-1.local`. If `nightwatch.local` still works but `nightwatch-1.local` doesn't, nodeconfig may have failed — check logs with `sudo journalctl -u nightwatch-firstboot`.

### After `make image`, the Pi has failing services

This is expected. `make image` strips all node-specific config (.env, .node-number, ngircd.conf) to prepare the SD card as a golden image for cloning. **The card is no longer meant to be used as a live node.** To continue using it:
- Either re-run firstboot: `sudo rm -f /opt/nightwatch/.firstboot-done && sudo /opt/nightwatch/scripts/firstboot.sh`
- Or use the card as intended: shut down, `dd` the image, and flash clones

### Docker pulls fail / no internet even though WiFi is connected

The GL.iNet router on eth0 gives the Pi a default route with no internet, shadowing the wlan0 route that does have internet. nodeconfig and mesh-fix.sh both fix this automatically, but if you hit it manually:
```bash
sudo ip route del default dev eth0
```

### USB WiFi dongle (wlan1) disappears or becomes unresponsive

The ath9k_htc firmware can crash if NetworkManager repeatedly reclaims the interface. nodeconfig now writes a permanent rule to prevent this (`/etc/NetworkManager/conf.d/nightwatch-mesh-unmanaged.conf`). If the dongle is already in a bad state, unplug it, wait 5 seconds, and plug it back in. Then `sudo systemctl restart nightwatch-mesh`.

### Can I reuse the golden image SD card as a normal node?

Yes, but you need to re-run firstboot since `make image` removed the setup stamp:
```bash
sudo rm -f /opt/nightwatch/.firstboot-done
sudo /opt/nightwatch/scripts/firstboot.sh
```

### All my cloned Pis have the same hostname

Each clone auto-assigns a unique number on first boot via MAC-based sorting. If they all show `nightwatch` instead of `nightwatch-N`, nodeconfig didn't complete. Check `sudo journalctl -u nightwatch-firstboot` on the affected node. Common causes: wlan1 dongle not plugged in, or firstboot hit an error before nodeconfig could finish.

### `make test` shows nginx FAIL after reboot

If nginx shows `status=created` instead of running, Docker Compose didn't fully start. Run `make run` to restart all services, or `sudo systemctl restart nightwatch-docker`.

## Security

- **Mesh encryption**: Set `MESH_SAE_PASSWORD` in `.env` for WPA3-level SAE on all mesh links
- **WiFi encryption**: Router broadcasts WPA2 (set via `WIFI_PASSWORD`)
- **IRC federation**: `IRC_LINK_PASSWORD` secures server-to-server links
- **Secrets in .env**: File is gitignored, never committed
- **Generated configs**: `ngircd.conf` is regenerated by the discovery daemon (link passwords never in git)
- **Local-only traffic**: All mesh traffic stays on the mesh, never touches internet

## TODO

- [ ] Remove Docker dependency — run ngircd, nginx, and irc-bridge natively via systemd (less RAM, faster boot, simpler debugging, better for Pi Zero 2W)
- [ ] Add captive portal — redirect new WiFi clients to the chat page automatically
- [ ] Support channel persistence — IRC history survives container restarts
- [ ] Add mesh network map to web UI — show topology, latency, and node status
- [ ] Add monitoring/alerting — detect and notify when nodes go offline

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
