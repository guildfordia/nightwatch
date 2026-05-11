# Capacity planning: how many simultaneous visitors?

Designing a Nightwatch deployment for an event (vernissage, talk,
exhibition opening). Numbers below assume the **default radio
config** (AR9271 dongles, `max_num_sta=8` per AP, mesh AR9271).

## TL;DR

| Visitors expected at peak | Pi nodes you need | Subnet | Confidence |
|---------------------------|-------------------|--------|------------|
|  ≤ 32                     |  4                | /24    | **High** — sim validated |
|  ≤ 80                     | 10                | /24    | **High** — sim validated |
|  ≤ 96                     | 12                | /24    | **High** — sim validated up to 12 nodes |
|  ≤ 104                    | 13                | /24    | **Medium** — extrapolation; race fix landed |
|  ≤ 160                    | 20                | /24    | **Medium** — needs §7.3 grandeur nature |
|  ≤ 224                    | 28                | /24    | **Low** — at the /24 architectural limit |
|  ≤ 240                    | 30                | **/23**| **Low** — needs subnet migration + §7.3 |
| > 240                     | hardware change required (see below) | | |

**Confidence levels above:**
- **High**: tested in the sim, no architectural concern.
- **Medium**: math fits the architecture, but mesh-radio
  contention and per-Pi convergence at this scale haven't been
  observed on real hardware. CdC §7.3 grandeur nature is the
  validation gate.
- **Low**: requires changes (subnet migration, MAX_NODES bump
  past 28) beyond what the current sim has exercised.

For any new deployment past 12 nodes the grandeur-nature test
must precede the public event — the sim cannot reproduce 2.4 GHz
shared-channel contention between 20-30 physical Pis in the
same venue.

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

1. **Add more nodes** within `/24` — bumpez `MAX_NODES` (env var
   in `scripts/common.sh`) up to **28**. The DHCP layout already
   handles 28 × 8 = 224 baux without conflicts (verified math:
   static node IPs .101-.128, anchor .1, broadcast .255 reserved;
   DHCP at .121-.248 + .2-.97 = 224 IPs available). Past 28 you
   hit the /24 ceiling and must migrate the subnet.
2. **Better AP radio (no other software change)**. Swap the AP-side
   AR9271 for an **MT7612U** (~€35/dongle). The mesh-side AR9271 can
   stay. MT7612U handles 25-30 stations cleanly and removes the
   firmware crash mode. Per the existing README note: "Same-venue
   100-user is realistic in this configuration." With 6-8 MT7612U
   nodes you cover the 100-user event from a smaller mesh.
3. **Bigger subnet** for 30+ nodes. Move `192.168.199.0/24` to
   `/23` (192.168.198.0/23 = 510 hosts) or `/22` (1022 hosts).
   Touch points:
   - `scripts/common.sh` — mesh IP computation, DHCP range math,
     anchor IP address.
   - `scripts/mesh-fix.sh` and `scripts/nodeconfig.sh` — br0
     netmask must change from `/24` to `/23` (or `/22`).
   - `dhcp-range` line in `generate_dnsmasq_conf` — last field is
     the netmask, must match.
   - `dhcp-option=3,${mesh_ip}` (gateway) stays the same since
     the mesh IP is still in the wider range.
   - Test scripts that hardcode `.101-.120` regex (e.g.
     `test-mesh.sh:88`, `test-scan.sh`) — update to span the
     new range.
   This is a real migration, not a constant bump. **Not
   validated in this codebase**. Plan a §7.3 grandeur-nature
   day specifically for the subnet change.

### Known risks at higher node counts

The sim cannot exercise these, only physical Pi tests can:

- **2.4 GHz channel contention** between 20-30 Pis in the same
  venue. The mesh radio (wlan1) and the AP radio (wlan2 if used,
  AR9271 by default) all broadcast OGMs and management frames on
  the same channel. Past ~15 Pis in close radio range, expect
  measurable mesh convergence time (30-60 s on cold start) and
  occasionally lost OGM batches.
- **AR9271 firmware stability** on the mesh side under sustained
  high node count. The 8-station cap on the AP-side AR9271 is
  documented; the mesh-side AR9271 has its own quirks at scale.
- **batman-adv routing-table size**. At 30 nodes × 8 stations =
  240 MAC addresses, batman-adv DAT (Distributed ARP Table) holds
  several hundred entries. Tested up to 100+ in batman-adv
  benchmarks, so headroom exists, but not exercised by us.

The CdC §7.3 grandeur nature is the validation gate for any of
these. Without it, the high-node-count rows in the table above
are math projections, not guarantees.

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
