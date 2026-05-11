# Capacity planning: how many simultaneous visitors?

Designing a Nightwatch deployment for an event (vernissage, talk,
exhibition opening). Numbers below assume the **default radio
config** (AR9271 dongles, `max_num_sta=8` per AP, mesh AR9271).

## TL;DR

| Visitors expected at peak | Pi nodes you need | Subnet |
|---------------------------|-------------------|--------|
|  ≤ 32                     |  4                | /24 OK |
|  ≤ 80                     | 10                | /24 OK |
|  ≤ 96                     | 12                | /24 OK |
|  ≤ 104                    | 13                | /24 OK |
|  ≤ 120                    | 15                | /24 OK |
|  ≤ 160 *(theoretical max)*| 20                | /24 OK |
| > 160                     | hardware change required (see below) |

Formula: `peak_visitors = floor(8 × N_nodes)`.

## Why 8 per node?

`hostapd max_num_sta = 8` is set in `scripts/common.sh:255` for
hardware stability. The AR9271 firmware becomes unstable past
12-15 stations and crashes the kernel. 8 is the conservative cap
shipped per CdC §3.4 #11.

This is **not** a software limit you can lift cheaply — it's the
radio chipset. With this radio, 8 stations per AP is the safe ceiling.

## How to scale beyond 160 visitors

Three options, ordered by cost:

1. **Add more nodes**. Up to `MAX_NODES = 20` is already wired in
   the DHCP layout. `scripts/common.sh:17` ; can bump to 24-30 by
   editing that constant + the DHCP-range math, no other changes
   needed (`/24` has room for 8 × 30 = 240 baux).
2. **Better AP radio (no other software change)**. Swap the AP-side
   AR9271 for an **MT7612U** (~€35/dongle). The mesh-side AR9271 can
   stay. MT7612U handles 25-30 stations cleanly and removes the
   firmware crash mode. Per the existing README note: "Same-venue
   100-user is realistic in this configuration." With 6-8 MT7612U
   nodes you cover the 100-user event from a smaller mesh.
3. **Bigger subnet**. Move `192.168.199.0/24` to `/23` (510 hosts)
   or `/22` (1022 hosts). Edits: `scripts/common.sh` (mesh IP
   computation, DHCP range), `dhcp-option=3/6` netmask. No new
   tech, just wider addressing. Only worth it past 160 stations.

## Event-night tuning (no code changes, just env)

For a vernissage with churn (people come, stay 15-30 min, leave),
shorten the DHCP lease so freed IPs recycle quickly:

```sh
# /etc/default/nightwatch
NIGHTWATCH_DHCP_LEASE=10m   # default is 1h
```

With a 10-min lease, the **effective** capacity over a 3 h evening
is much higher than the per-instant cap, because phones that left
free their slot for the next arrivals.

For the bridge cap (per-node WS ceiling):

```sh
# /etc/default/nightwatch
NIGHTWATCH_MAX_CONNS=48     # default 40, headroom for debug-tab usage
```

This is the 503-saturation threshold; the captive portal's
"Trop de monde" banner triggers above it (`html/index.html`).

## What's already calibrated

The defaults form a coherent envelope:

- `hostapd max_num_sta` = 8 (CdC §3.4 #11)
- DHCP pool                = 8 IPs/node
- `maxConnsGlobal`        = 40 WS/node = 8 phones × 5 connections
- `replayBufferSize`      = 100 messages = ~15 s of history at 7 msg/s peak

Any deployment with `≤ MAX_NODES × 8` simultaneous visitors fits
without touching code. Beyond that, the unlock paths are listed
above.

## What's NOT a limit

These looked like limits but aren't, after audit:

- **ngircd `MaxConnections = 150`** per node — 8 phones × 5 WS +
  19 peer links = 60. Headroom 60 %.
- **`/24` subnet** — 254 addresses, currently using 160 baux (20
  nodes × 8). 60 % free.
- **Captive portal page memory** — ~12 KB HTML, doesn't scale with
  visitor count.
- **ngircd federation traffic** — at 100 phones × 1 msg / 15 s =
  6.7 msg/s aggregate, spread across the spanning tree, negligible.
- **mesh radio throughput** — chat is tiny (200 B/message); the
  mesh is sized for video bandwidth (CdC §3.4 #2) which is orders
  of magnitude more demanding.
