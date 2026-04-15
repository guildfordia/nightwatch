# NIGHTWATCH - Decentralized Mesh Chat

![Nightwatch Banner](https://img.shields.io/badge/NIGHTWATCH-Mesh%20Network%20Terminal-blue?style=for-the-badge)

A resilient chat system for off-grid communication using 802.11s + batman-adv mesh networking. Zero infrastructure required — just power, Raspberry Pis, and two cheap USB WiFi dongles per node.

## Architecture

```
                          802.11s mesh (wlan1, USB dongle #1)
                         /            |             \
                      [Pi 1]       [Pi 2]         [Pi 3]  ...  [Pi N]
                       bat0          bat0           bat0          bat0
                        |             |              |             |
                       br0           br0            br0           br0
                       /\           /\              /\            /\
                  bat0  wlan2  bat0  wlan2     bat0  wlan2   bat0  wlan2
                        |           |                |             |
                    hostapd     hostapd          hostapd       hostapd
                    (WiFi AP)   (WiFi AP)        (WiFi AP)     (WiFi AP)
                       |           |                |             |
                    clients     clients          clients       clients

   Optional: one node has wlan0 → internet (gateway mode)
   Optional: sound-bridge mode — eth0 → Mac Mini on 10.0.0.1/24
```

Each Pi runs:
- **wlan1** (USB dongle #1) — 802.11s mesh with batman-adv for multi-hop routing
- **wlan2** (USB dongle #2) — hostapd WiFi AP for client connections
- **bat0** — batman-adv virtual interface, carries all mesh traffic
- **br0** — Linux bridge joining bat0 + wlan2, holds the mesh IP
- **wlan0** (onboard) — reserved for internet/Tailscale (not used by mesh)
- **eth0** — unused in default mesh mode (used in sound-bridge mode for Mac Mini)
- **Native systemd services** — ngircd (IRC), irc-bridge (Go WebSocket), nginx (web frontend)

Users connect to "Nightwatch" WiFi and access the chat. Traffic routes through the mesh automatically via batman-adv.

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

### Auto-Recovery Watchdog

A systemd timer runs `mesh-watchdog.sh` every 30 seconds to detect and recover from common failures:

| Check | Action if failed |
|-------|------------------|
| `nightwatch-mesh.service` is active | Restart mesh service |
| `wlan1` exists and in mesh mode | Restart mesh service |
| `wlan1` is in batman-adv | Restart mesh service |
| `hostapd` is running (skipped in sound-bridge mode) | Restart mesh service |
| `wlan2` exists (skipped in sound-bridge mode) | Restart mesh service |

Escalating recovery (after consecutive failures):
1. **Failures 1-2**: `systemctl restart nightwatch-mesh`
2. **Failures 3-4**: USB reset both AR9271 dongles, then restart mesh
3. **Failures 5-6**: Full Pi reboot (recovers from ath9k_htc interface name swaps)

## Features

- **802.11s + batman-adv** — real multi-hop mesh routing (not just single-hop ad-hoc)
- **hostapd WiFi AP** — Pi acts as its own AP via second USB dongle (no external router needed)
- **Shared BSSID across nodes** — all APs broadcast the same MAC, clients roam at Layer 2
- **802.11r Fast Transition** (optional) — sub-second roaming for compatible clients
- **Dynamic node assignment** — flash and boot, no configuration needed
- **SAE encryption** — optional WPA3-level security on mesh links
- **Automatic peer discovery** — UDP broadcast, no manual config
- **IRC federation** — linked servers across nodes, messages sync everywhere
- **Self-healing** — routes around failed nodes in seconds
- **Auto-recovery watchdog** — detects dongle crashes, reboots if needed
- **Gateway support** — one node can share internet to the whole mesh
- **Sound-bridge mode** — eth0 hosts a Mac Mini on a separate subnet for audio
- **Captive portal** — DNS hijacking + RFC 8908/8910 API for Android 11+
- **DoT interception** — port 853 redirected to local DNS
- **dnsmasq DHCP** — Pi serves DHCP to WiFi clients on br0
- **Terminal-style web UI** — clean, fast, works on any device
- **In-chat `/blink` command** — blink the Pi's LED to identify which node you're connected to
- **Persistent nicknames** — saved in localStorage, reclaimed on reconnect
- **Integration test suite** — `make test` verifies mesh, services, and cross-node IRC
- **Golden image cloning** — set up one Pi, clone to all others
- **Scales to 20 nodes**

## Hardware Requirements

### Per Node
- **Raspberry Pi 4/5** (recommended), Pi 3B+, or **Pi Zero 2 W** (with powered USB hub)
- **TWO USB WiFi dongles** with the same chipset:
  - **wlan1** for 802.11s mesh
  - **wlan2** for hostapd AP
- **MicroSD card** (32GB+ Class 10)
- **Power supply** (5V/3A for Pi 4, 5V/5A for Pi 5, 5V/2.5A for Pi 3, powered hub for Pi Zero 2 W)

### Recommended Dongles
| Dongle | Chipset | Driver | Price | Notes |
|--------|---------|--------|-------|-------|
| Generic AR9271 | AR9271 | ath9k_htc | ~$10 | Cheapest, widely tested, occasional firmware crashes (watchdog handles) |
| ALFA AWUS036ACM | MT7612U | mt76 | ~$35 | Best performance, dual-band |
| Generic RT5370 | RT5370 | rt2800usb | ~$5 | Budget option |

Verify mesh + AP support: `iw phy phy1 info | grep -E "mesh point|AP"` (check for both modes)

### Sound-Bridge Node (optional)
- A Pi configured with `NODE_MODE=sound-bridge` connects to a Mac Mini via eth0 on `10.0.0.0/24`
- The Mac Mini gets `10.0.0.1/24` as gateway, used for audio streaming
- Sound-bridge nodes still participate in the mesh but don't broadcast a WiFi AP

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
# 2. Plug in BOTH USB WiFi dongles
# 3. Keep SD card mounted and prepare it:

# Linux:
make sdcard SD=/dev/sdX

# macOS:
make sdcard SD=/dev/diskN

# 4. Insert SD card in Pi, boot, wait ~10-15 min for firstboot to complete
# 5. SSH in and verify:
ssh user@<pi-ip>
sudo make -C /opt/nightwatch test

# 6. Build the golden image:
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

# 2. Install (installs hostapd, dnsmasq, configures mesh + AP, sets up services)
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

# ── WiFi AP (hostapd on wlan2) ──
AP_IFACE=wlan2
AP_CHANNEL=6
AP_BSSID=02:00:4E:57:00:01    # Shared across all nodes for seamless roaming
WIFI_SSID=Nightwatch
WIFI_PASSWORD=Nightwatch

# ── Node Mode ──
# mesh         (default) bat0 + hostapd AP bridged via br0
# gateway      Same as mesh + batman-adv gw_mode server + NAT via INET_IFACE
# sound-bridge eth0 on separate subnet (10.0.0.1/24) for Mac Mini, no AP
NODE_MODE=mesh
# INET_IFACE=wlan0

# ── App Services ──
IRC_PORT=6667
NGINX_PORT=80

# ── IRC Federation ──
# Must be IDENTICAL on all nodes for server linking to work
IRC_LINK_PASSWORD=<set-during-install>

# ── Tailscale (optional remote SSH) ──
TAILSCALE_AUTH_KEY=

# ── Hugging Face (optional AI features) ──
HF_TOKEN=
```

> **Note:** Configs (`hostapd.conf`, `dnsmasq.conf`) are regenerated from `.env` on every `nightwatch-mesh.service` start, so editing `.env` and running `systemctl restart nightwatch-mesh` is enough to apply changes.

## Management

```bash
make install      # First-time setup (run once per Pi)
make run          # Start mesh + services
make stop         # Stop everything
make test         # Full integration test (mesh, services, cross-node IRC)
make update       # Pull latest code, restart
make status       # Show mesh and service status
make logs         # Follow service logs
make monitor      # Live dashboard (refreshes every 5s)
make blink        # Blink onboard LED to identify this Pi (CLI version)
make sdcard       # Prepare SD card for a new node (run on laptop, Linux/macOS)
make build-bridge # Cross-compile irc-bridge for ARM64 (run on laptop, auto in sdcard)
make image        # Prepare this Pi for golden image capture
make info         # Print detailed node information
```

### In-chat commands (from any phone connected to Nightwatch WiFi)

| Command | Action |
|---------|--------|
| `/nick <name>` | Change your nickname (saved in localStorage, persists across reconnects) |
| `/blink` | Blink the LED on the Pi you're currently connected to (10 seconds) |
| `/nodes` | Show mesh network map |
| `/debug` | Show full node diagnostics |
| `/help` | List commands |

## How the Mesh Works

1. **802.11s** creates wireless links between neighboring nodes (wlan1, USB dongle #1)
2. **batman-adv** (kernel module) builds a Layer 2 mesh on top — handles multi-hop routing, topology discovery, and self-healing
3. **br0** (Linux bridge) joins bat0 + wlan2; bat0 is added manually, wlan2 is added by hostapd via its `bridge=br0` directive
4. **br0's MAC is pinned to bat0's MAC** so it stays unique per node (without this, batman-adv's DAT gets confused by the shared hostapd BSSID)
5. **hostapd** on wlan2 broadcasts "Nightwatch" with the shared BSSID `02:00:4E:57:00:01`
6. **dnsmasq** on the Pi serves DHCP + captive portal DNS to clients on br0
7. **Native services** (ngircd, irc-bridge, nginx) bind to br0's IP, reachable from any client
8. **Node discovery** broadcasts on bat0, auto-configures ngircd federation
9. A user on any node's WiFi can reach any service on any node, and chat messages sync via IRC federation

## Captive Portal

The chat is reachable at `http://192.168.199.1` (shared IP across all nodes). To make modern phones auto-open the chat:

- **DNS hijacking** — all domains resolve to the Pi's mesh IP, so any URL in the browser loads the chat
- **HTTP redirect** — well-known captive-portal probe URLs (`/generate_204`, `/hotspot-detect.html`, etc.) return responses that signal a captive portal
- **DHCP option 114 (RFC 8910)** — points to the captive portal API
- **/api/captive (RFC 8908)** — returns `{"captive": true, "user-portal-url": "http://192.168.199.1/"}`
- **DoT (port 853) interception** — encrypted DNS is redirected to local dnsmasq

> **Note:** Modern Android (especially Samsung) is aggressive about switching back to networks with real internet. If the user has another saved WiFi nearby with internet, Android may silently switch back. Best results in genuinely off-grid environments.

## Multi-Node Deployment

Node numbers and IPs are assigned automatically on first boot:

| Node | PI_NUMBER | MESH_IP | Role |
|------|-----------|---------|------|
| Node 1 | 1 | 192.168.199.101 | Regular |
| Node 2 | 2 | 192.168.199.102 | Regular |
| Node 3 | 3 | 192.168.199.103 | Sound-bridge or Gateway |
| ... | ... | ... | ... |

**Using golden image (recommended):**
1. Flash `nightwatch.img.xz` to each SD card with Pi Imager
2. Boot each Pi — it auto-assigns a unique node number
3. Nodes discover each other and form the mesh automatically

**Manual setup:**
1. Run `make install` on each Pi
2. Ensure `IRC_LINK_PASSWORD` is the **same** on all nodes
3. `make run` on each node
4. Nodes auto-discover and mesh. Users connect to "Nightwatch" WiFi.

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
ls /sys/class/net/br0/brif/    # Should show bat0 and wlan2
ip addr show br0               # Should have 192.168.199.10X

# hostapd not running?
sudo hostapd_cli -i wlan2 status  # state=ENABLED expected
sudo journalctl -t hostapd --no-pager -n 30

# IRC federation broken?
sudo journalctl -u ngircd --no-pager 2>&1 | grep -i "bad password\|server\|link"
# If "Bad password" → IRC_LINK_PASSWORD doesn't match between nodes

# No clients getting DHCP?
sudo systemctl status dnsmasq
cat /var/lib/misc/dnsmasq.leases

# Watchdog logs (auto-recovery)
sudo journalctl -t nightwatch-watchdog --no-pager -n 30
```

## FAQ

### My phone connects briefly but switches back to home WiFi

Modern Android/Samsung's "Smart WiFi" switches away from networks without internet. The Nightwatch network is genuinely off-grid (no internet by design), so Android may avoid it when a network with internet is in range. Workarounds:
- Disable "Intelligent Wi-Fi" / "Switch to mobile data" in Android settings
- Forget the home WiFi temporarily (only for testing)
- Enable **gateway mode** on one node — gives the mesh real internet, Android stays happily

### I can't SSH to `nightwatch-N.local` after first boot

The Pi needs ~2 minutes to complete the first boot cycle: nodeconfig waits 60s for mesh convergence, then assigns a node number and sets the hostname. Wait 2-3 minutes after powering on, then try `ping nightwatch-1.local`.

### After `make image`, the Pi has failing services

This is expected. `make image` strips all node-specific config (.env, .node-number, ngircd.conf, hostapd.conf, dnsmasq.conf) to prepare the SD card as a golden image for cloning. **The card is no longer meant to be used as a live node.** To continue using it:
- Either re-run firstboot: `sudo rm -f /opt/nightwatch/.firstboot-done && sudo /opt/nightwatch/scripts/firstboot.sh`
- Or use the card as intended: shut down, `dd` the image, and flash clones

### USB WiFi dongle (wlan1 or wlan2) disappears or becomes unresponsive

The ath9k_htc firmware can crash. The watchdog auto-recovers via:
1. mesh service restart
2. USB device reset
3. Full Pi reboot (last resort)

If you want to manually recover: `sudo systemctl restart nightwatch-mesh`. If wlan1 and wlan2 swap (after driver reload), reboot the Pi — udev will assign them by USB port path.

### Phone authenticates but no DHCP / can't reach chat

This was a real bug — batman-adv's BLA (Bridge Loop Avoidance) was deauthing clients whose MAC was registered to a different node. The fix is in `setup_client_bridge()`: br0's MAC is pinned to bat0's MAC before hostapd adds wlan2, so each node's bridge has a unique MAC.

If you still see this: `sudo batctl meshif bat0 bl 0` to disable BLA on the affected node.

### Nick changes to `guestNNN` after walking out of range and back

The bridge now sends `QUIT` to the IRC server on WebSocket disconnect, releasing the nick immediately. On reconnect, the saved nick (in localStorage) is reclaimed automatically. If your nick is still locked (e.g., during the brief window before QUIT lands), wait 30 seconds and reconnect.

### Both my Pis broadcast "Nightwatch" — does my phone roam between them?

With shared BSSID enabled, both APs look like the same AP. The phone's WiFi stack treats it as a single network and roams transparently when the signal weakens. For 802.11r Fast Transition (sub-second handoff), enable FT-PSK in `hostapd.conf` — but some Samsung phones reject FT-PSK, so it's disabled by default.

## Security

- **Mesh encryption**: Set `MESH_SAE_PASSWORD` in `.env` for WPA3-level SAE on all mesh links
- **WiFi encryption**: hostapd broadcasts WPA2-PSK (set via `WIFI_PASSWORD`)
- **IRC federation**: `IRC_LINK_PASSWORD` secures server-to-server links
- **Secrets in .env**: File is gitignored, never committed
- **Generated configs**: `ngircd.conf`, `hostapd.conf`, `dnsmasq.conf` are regenerated at runtime (no secrets in git)
- **Local-only traffic**: All mesh traffic stays on the mesh, never touches internet

## Recent Changes (this branch)

- **Replaced GL.iNet router with hostapd** on a second USB WiFi dongle — full control over BSSID, no external hardware needed
- **Shared BSSID across all nodes** for transparent Layer-2 roaming
- **802.11r support** in hostapd.conf (FT-PSK, currently disabled by default for Samsung compatibility)
- **Bridge MAC pinning** in `setup_client_bridge()` — fixes batman-adv DAT confusion with shared BSSID
- **Auto-recovery watchdog** with escalating recovery (restart → USB reset → reboot)
- **Sound-bridge mode** properly handles eth0/Mac Mini in the new architecture
- **Captive portal** improvements: RFC 8908/8910 API, DHCP option 114, DoT interception
- **Always regenerate** `dnsmasq.conf` and `hostapd.conf` on mesh service start (prevents stale configs)
- **IRC bridge sends QUIT** on WebSocket disconnect for instant nick release
- **`/blink` chat command** to identify which node you're connected to
- **Captive portal `/api/captive`** endpoint for Android 11+ Captive Portal API

## TODO

- [ ] Improve captive portal compatibility with Samsung's HTTPS connectivity check (needs valid TLS cert or local-only solution)
- [ ] Add udev rules for persistent wlan1/wlan2 naming (avoid swap after driver reload)
- [ ] Support channel persistence — IRC history survives service restarts
- [ ] Add mesh network map to web UI — show topology, latency, and node status
- [ ] Add monitoring/alerting — detect and notify when nodes go offline
- [ ] Test 802.11r in production deployment with non-Samsung devices

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
