# Nightwatch — Operations Runbook

This is the troubleshooting + recovery guide for the live deployment. The README explains *what* Nightwatch is; this document explains *what to do when something breaks*, especially during an event with limited time.

If you have 30 seconds and a node is down at an event, **jump to [Quick decision tree](#quick-decision-tree)**.

## Fleet topology at a glance

| Component | Where | Role |
|---|---|---|
| 6× Raspberry Pi (2-7) | venue | Mesh nodes. Each runs nightwatch-mesh, nightwatch-discovery, nightwatch-debug, nightwatch-bridge, ngircd, hostapd, dnsmasq, nginx. |
| `nightwatch-2` (seed) | venue | Plays the same role as 3-7 + is LAN-routable from the gateway (the others are mesh-only). New nodes discover the fleet through this one. |
| `mac-mini` | home / venue | Tailscale gateway. SSH ProxyJump entrypoint to reach the mesh from outside the venue's LAN. |
| `station` | home | Linux box running `mesh-doctor` (`~/mesh-doctor/`) for fleet diagnostics. |
| `~/.ssh/config` aliases | station + your devices | `mac-mini` (gateway), `nightwatch-2` (LAN-routable seed), `mesh` (= `nightwatch-2`), `nightwatch-*` (any peer through ProxyJump). |

For full architecture see `README.md`. For the diagnostic tool see `~/mesh-doctor/README.md`.

## Quick decision tree

When something looks broken, work through these in order. Most problems resolve at the first or second step.

### "A phone can't connect to Nightwatch"

```
1. Check all 6 nodes are up:    mesh-doctor status
   - If <6 reachable          → see "Node N offline" below
   - If all 6 reachable, AP=0 → DHCP exhaustion or hostapd issue
                                 ssh nightwatch-2 'sudo journalctl -u nightwatch-mesh -n 30'
2. Check phone has signal to ANY AP (ask user to walk closer to a node)
3. Check captive portal popped on phone — if not, in browser try
   http://chat.nightwatch or http://192.168.199.1
4. If phone is connected but chat won't load:
   - DNS lookup might be sticky (old node IP) → toggle phone WiFi off+on
   - Or the user roamed and WebSocket is broken → refresh the browser tab
```

### "Node N offline"

```
1. Check power LED on the Pi.
   - Off / dim          → power supply / cable problem. Reseat USB-C.
                          If still off, swap PSU (nominal 5V 2.5A or better).
2. Check activity LED.
   - Solid / very slow  → kernel hung. Hard power-cycle (pull power 30s).
3. Check both AR9271 dongles' LEDs.
   - Either one off     → reseat USB. If still off, swap dongle.
4. SSH check from station:
     ssh nightwatch-N 'uptime; ip a | grep -E "wlan|bat0|br0"'
   - SSH works, no wlan1 → USB driver crash. Run:
       mesh-doctor fix usb-reset N
   - SSH timeout         → physical fault, see steps 1-3.
5. Last resort: reflash SD card from the latest known-good image.
```

### "Mesh is partitioned" (some nodes can't see others)

```
1. Run:                  mesh-doctor topology
   - Shows multiple disconnected clusters in the federation tree
2. Identify the missing link:
     mesh-doctor diagnose
   - Look for "node_unreachable" or "mesh_isolated" findings
3. Most common cause: a hub node is dead. Bring it back.
   See "Node N offline" above.
4. If all nodes are individually up but mesh routes are broken:
     mesh-doctor fix restart-mesh-service N   # for each affected node
```

### "Chat works for some, not others"

```
1. mesh-doctor topology — verify ngircd federation has all nodes
2. If federation is split:
     mesh-doctor fix restart-mesh-service N  # for the affected hub node
   The full mesh-fix.sh restart regenerates ngircd.conf from current
   peer file and restarts ngircd.
3. After ~30-60s the federation should re-form and messages traverse.
```

## Common "this is normal but looks alarming" patterns

These are documented because we've all jumped at them in the past. Don't waste time on them.

| Symptom | Why it's normal | When to actually worry |
|---|---|---|
| Phone shows "No internet" instead of internet symbol | Captive portal is intentionally serving a fake DNS (every name → local node). Real internet not provided. | Never. This is the design. |
| Same MAC appearing in 4 different nodes' AP station tables | One phone roamed across nodes; each AP keeps the entry for ~30-60s after the phone leaves. | If `inactive_ms` < 1000 on >1 node simultaneously — that's actual interference. |
| `mesh-doctor` shows `flapping` finding for a node | Node has gone up/down ≥4 times in last 50 events. | Check power + cables. Don't restart the service — it's already restarting. |
| `discovery_silent` finding right after deploy | nightwatch-debug.sh on that node hasn't picked up the latest peer file format. | Run `mesh-doctor fix apply-debug-bugfix N` once, should self-resolve after. |
| `client_churn` finding under load | No 802.11r → every roam logs as 1 disconnect + 1 connect. With phones moving around, this fires. | If churn is happening with no users physically moving — then something's actively broken. |
| Connection time from station to a Pi is 3-5s (cold) | First SSH through ProxyJump pays the handshake cost. Subsequent calls reuse ControlMaster, ~50ms. | If warm calls also take >1s. |

## Recovery commands cheat-sheet

```sh
# Live fleet view
mesh-doctor status
mesh-doctor watch                # 2s refresh

# Find the problem
mesh-doctor diagnose
mesh-doctor topology
mesh-doctor logs nightwatch-2 nightwatch-3   # multiplex journalctl

# Fix common issues (all idempotent, ask before doing red ones)
mesh-doctor list-playbooks
mesh-doctor fix restart-mesh-service N       # 🟢 safe — restart the mesh stack on N
mesh-doctor fix restart-discovery N          # 🟢 safe — restart node-discovery
mesh-doctor fix restart-debug-service N      # 🟢 safe — restart debug.json generator
mesh-doctor fix usb-reset N                  # 🟡 power-cycles AR9271 dongles on N
mesh-doctor fix regenerate-configs N         # 🟡 full stop+start of nightwatch-mesh
mesh-doctor fix apply-debug-bugfix N         # 🟡 patches the JSON-bug variant on N
mesh-doctor fix reboot-node N                # 🔴 reboots the Pi (60-90s offline)

# Direct SSH access for poking
ssh nightwatch-2                             # LAN-routable seed (via mac-mini ProxyJump)
ssh nightwatch-3                             # any peer (via mac-mini ProxyJump)
ssh -J nightwatch-2.local user@192.168.199.10X    # if the alias doesn't resolve
```

## Hardware swap procedure

When a Pi is dead and needs replacement during an event.

1. **Prepare a spare SD card in advance.** Image with the latest `prepare-sdcard.sh` output, identical `.env` template, all 6 nodes' worth of images written and labelled.
2. **Pull the dead Pi.** Note its number (the SD card or label tells you).
3. **Insert the matching spare.** First boot: nightwatch-firstboot.service runs nodeconfig which assigns the right node number based on the slot in the peer file (or the `.env` if pre-baked).
4. **Wait ~60s** for the new node to discover peers and federate ngircd.
5. **Verify**: `mesh-doctor status` should show 6/6 reachable within 1-2 minutes.

If you don't have spare SD cards: a Pi with the dead node's number cannot be cloned on-the-fly during an event. **Pre-image at least 1 spare per deployed Pi.**

## Reflash procedure (between events)

When an SD card is corrupt or you want to update.

1. On station: `cd ~/Code/nightwatch-raspi && bash scripts/prepare-sdcard.sh` — interactive, asks for the target node number, writes to a connected SD card reader.
2. The image is bootable + opinionated: first boot runs firstboot.sh which does the rest.
3. Power on the Pi. After ~2-3 minutes it should appear in `mesh-doctor status`.

## Known limitations (expected behavior, not bugs)

- **No 802.11r fast roaming** by default. Roaming between APs takes 1-3s. See `docs/phase-c-802.11r-fast-roaming.md` for the gated opt-in path.
- **No 802.11k/v** in default builds (they're a 3-line opt-in addition; see `/tmp/deploy-phase-d-80211kv.sh` if it's been run).
- **DHCP pool is 5 IPs per node** (= 30 fleet-wide). With phones distributing unevenly, you'll hit `dhcp_pool_full` on hot AP nodes before reaching 30 total clients.
- **Mesh is unencrypted by default** (`MESH_SAE_PASSWORD` is optional). Anyone with a Wi-Fi card can sniff the mesh traffic.
- **Replay buffer is 50 messages, in-memory** — chat history is lost on node restart. Per-bridge, not federated.
- **Detection of unplanned node death** takes 90s (`PEER_TIMEOUT` in node-discovery.sh) before the IRC federation rebuilds.

## Captive portal cross-OS testing — TODO

Before the next public deployment, walk through the captive portal flow on each platform and document what the user sees:

- [ ] iOS 16+ (CNA: connects to `captive.apple.com`, expects `<HTML><HEAD><TITLE>Success</TITLE></HEAD>...`)
- [ ] Android 11+ (Network Validation: `connectivitycheck.gstatic.com/generate_204`)
- [ ] Android with Samsung firmware (some refuse FT-PSK; should be fine since FT off by default)
- [ ] macOS (CNA, similar to iOS)
- [ ] Windows (NCSI: `www.msftconnecttest.com/connecttest.txt`)

Note any rough edges (popup not appearing, fake-success required, etc.) in this section.

## Maintenance schedule

- **Weekly during an active deployment**: glance at `mesh-doctor diagnose` for unresolved findings; review last 50 lines of `events.jsonl`.
- **Monthly**: backup `.env` files from each Pi, prune `/opt/nightwatch/scripts/*.bak.*` files older than 30 days.
- **Per-event**: pre-flight checklist (all 6 nodes up, mesh-doctor watch shows green, captive portal verified on test phone, AP traffic data flowing in real time).

## When you don't know what's wrong

In order:

1. `mesh-doctor diagnose` — most things show up here as findings with suggested playbooks.
2. `tail -50 ~/mesh-doctor/state/events.jsonl` — what changed recently?
3. `ssh nightwatch-N 'sudo journalctl -u nightwatch-mesh -u nightwatch-bridge -u nightwatch-debug -n 100 --no-pager'` — system journal for a single node.
4. Walk over and look at the LEDs.

The fleet is small enough (6 nodes) that brute-force inspection works. Don't over-engineer the debugging.
