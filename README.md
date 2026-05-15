# Nightwatch — Decentralized Mesh Chat

A resilient chat system for off-grid communication using 802.11s + batman-adv mesh networking. Zero infrastructure required — just power, Raspberry Pis, and two USB WiFi dongles per node.

Visitors connect their phone to the "Nightwatch" WiFi and chat through a captive web portal. Messages sync across all nodes via IRC federation over the mesh.

## Hardware per node

- Raspberry Pi 4 or 5 (Pi 3B+ and Zero 2 W also work)
- Two USB WiFi dongles with the same chipset (AR9271 cheap, MT7612U recommended)
- MicroSD card 32 GB class 10
- 5V power supply matching the Pi model

Verify mesh + AP support on each dongle: `iw phy phy1 info | grep -E "mesh point|AP"`

## Quick install

### Option A: Golden image (recommended for multiple nodes)

Set up one Pi, capture its SD card as an image, then flash that image to all the others.

```bash
# On laptop: prepare SD card
make sdcard SD=/dev/diskN     # macOS, or /dev/sdX on Linux

# Insert SD in Pi, boot, wait 10-15 minutes for first boot
# Then SSH in and verify:
ssh user@<pi-ip>
sudo make -C /opt/nightwatch test

# Once verified, build the golden image:
sudo make -C /opt/nightwatch image
sudo shutdown -h now

# Capture and clone (on laptop):
sudo dd if=/dev/rdiskN of=nightwatch.img bs=4m status=progress
sudo bash pishrink.sh nightwatch.img
xz -9 -T0 nightwatch.img

# Flash nightwatch.img.xz to other SD cards with Pi Imager.
# Each new Pi auto-assigns its own node number on first boot.
```

### Option B: Manual install (single Pi / development)

```bash
git clone https://github.com/guildfordia/nightwatch.git
cd nightwatch
make install
make run
make test
```

## Configuration

Auto-generated on first boot. See `.env.example` for the full template. Key knobs an operator typically tunes:

- `WIFI_SSID` / `WIFI_PASSWORD` — visitor WiFi credentials
- `IRC_LINK_PASSWORD` — must be **identical** on all nodes for IRC federation to work
- `NIGHTWATCH_MODE` — `production` (default) or `debug`
- `SIGNALEMENT_EMAIL` — required before any public deployment (LCEN/RGPD)

Apply changes:

```bash
sudo systemctl restart nightwatch-mesh
```

## Management

```bash
make install     # First-time setup
make run         # Start mesh + services
make stop        # Stop everything
make status      # Show mesh and service status
make test        # Full integration test
make update      # Pull latest code, restart
make wipe-logs   # Erase host logs on every node (end of exposition)
```

In-chat commands from any phone connected to the Nightwatch WiFi:

| Command | Action |
|---|---|
| `/nick <name>` | Change nickname (saved in localStorage) |
| `/help` | List commands |

Diagnostic commands (`/blink`, `/nodes`, `/debug`) are gated behind `NIGHTWATCH_MODE=debug`.

## Troubleshooting

```bash
make status                                      # Quick overview
make test                                        # Full integration test
sudo journalctl -t nightwatch-watchdog -n 30     # Auto-recovery logs
sudo journalctl -u ngircd -n 30                  # IRC federation logs
```

If a USB WiFi dongle becomes unresponsive, the watchdog automatically attempts recovery (service restart → USB reset → full reboot if persistent).

## License

MIT License — see [LICENSE](LICENSE).

## Companion project

Audio-visual sonification layer of the chat: [`nightwatch-sound`](https://github.com/guildfordia/nightwatch-sound).
