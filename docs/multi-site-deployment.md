# Multi-site deployment

If you want to run two simultaneous Nightwatch installations (different gallery, festival, friend's loft) without them interfering, you need to namespace the deployments. Otherwise nodes from site A will join site B's mesh, IP allocations will collide, and the chat federations will entangle.

This doc describes the variables you must override per-site, and the tooling around them.

## What needs to differ between sites

| Variable | Why it matters | Example values |
|---|---|---|
| `MESH_ID` | 802.11s mesh identifier — nodes only join meshes with the same ID | `nightwatch-paris-2026`, `nightwatch-tokyo-2027` |
| `MESH_SAE_PASSWORD` | mesh encryption key — site-specific secret, must be the same on every node *within* a site, different *across* sites | `openssl rand -base64 24` per site |
| `WIFI_SSID` | what testers see in their phone Wi-Fi list — should be visibly distinct so users don't accidentally join the wrong site | `Nightwatch-Paris`, `Nightwatch-Tokyo` |
| `WIFI_PASSWORD` | client-side WPA2-PSK password | distinct per site if both are simultaneously visible |
| `FREQ` | radio channel — co-located sites *must* use different channels to avoid RF contention | `2412` (ch 1), `2437` (ch 6), `2462` (ch 11) |
| `AP_CHANNEL` | hostapd AP channel — should match `FREQ` for cleaner RF | `1`, `6`, `11` |
| `AP_BSSID` | AP MAC — make different per site so phones don't try to roam between them | `02:00:4E:57:01:01` (paris), `02:00:4E:57:02:01` (tokyo) |
| Subnet (advanced) | the `192.168.199.0/24` prefix is hardcoded in many places. If two sites are physically separate this is fine; if they share infrastructure (uncommon) you'd need to refactor `mesh_ip_for_node` | n/a until needed |

## Site-config files

Suggested layout: a `sites/` directory at the repo root, one `.env`-format file per site:

```
sites/
  paris-2026.env
  tokyo-2027.env
  friend-loft.env
```

Each file overrides only the site-specific variables; everything else inherits from `.env.example` defaults.

Example `sites/paris-2026.env`:

```sh
SITE_NAME=paris-2026
MESH_ID=nightwatch-paris-2026
MESH_SAE_PASSWORD=<generated per-site key, never commit real keys>
WIFI_SSID=Nightwatch-Paris
WIFI_PASSWORD=visite-paris-2026
FREQ=2412
AP_CHANNEL=1
AP_BSSID=02:00:4E:57:01:01
```

Then at SD-card prep time:

```sh
SITE=paris-2026 scripts/prepare-sdcard.sh SD=/dev/diskX NODE=3
```

`prepare-sdcard.sh` reads `sites/${SITE}.env` and merges its values into the per-Pi `.env` written to the SD card.

## What `prepare-sdcard.sh` would need

(This is documentation of the change, not yet implemented in code — a small extension to the existing `prepare-sdcard.sh`):

```sh
# Near the top of prepare-sdcard.sh after argument parsing
SITE_FILE="sites/${SITE:-default}.env"
if [ "$SITE" != "default" ] && [ -f "$SITE_FILE" ]; then
    # Source site-config first; later .env writes override per-Pi specifics
    set -o allexport
    source "$SITE_FILE"
    set +o allexport
    echo "[+] Using site config: $SITE ($SITE_FILE)"
fi
```

Plus a `sites/default.env` (committable, no secrets) and a `sites/.gitignore` excluding `*.env` except `default.env`.

## What mesh-doctor would need

Currently `mesh-doctor` reads `~/mesh-doctor/state/nodes` which is a flat list. For multi-site, it needs to know which site it's polling. Two options:

1. Per-site `MESH_DOCTOR_*` env vars (separate state directories):
   ```sh
   MESH_DOCTOR_ROOT=~/mesh-doctor-paris ~/mesh-doctor/bin/mesh-doctor status
   ```
   Two parallel install dirs, run independently. Simplest.

2. Site-aware mesh-doctor that scopes commands by site flag. More invasive change, defer.

Recommended: do (1) when you actually have a second site. Two install dirs is trivial and avoids cross-site bugs.

## Operational considerations

- **Do NOT run two sites on adjacent channels** if they're in radio range of each other. Use 1/6/11 with at least one gap.
- **Pre-flash all SD cards for one site at a time.** Mixing site configs at SD prep time leads to confused deployments.
- **Document the active site on each Pi physically.** A piece of tape with `paris-2026` on the Pi case saves an hour of "which one is this?" when you're packing up.
- **Rotate `MESH_SAE_PASSWORD` between deployments**, even of the same site. Treat each event as a fresh secret. It only takes one stale phone in someone's pocket sniffing the previous deployment to leak.
- **Don't share `mesh-doctor` state across sites** — bake site name into the install directory.

## What's NOT solved by this scheme

- Two sites that are physically adjacent (same room, different installations) sharing the 2.4 GHz band will still degrade each other's throughput. There's no software fix; use 5 GHz hardware (different dongles) for one of them.
- Phones that have joined site A's SSID before will auto-connect when they're in range of site B's SSID *if* the SSID name is the same. Always make the SSID visibly distinct per site (not just MESH_ID).
- The captive portal on each site looks identical — testers might not realize they joined the wrong network. Consider including the site name in the captive portal page header.

## Future: dynamic site-from-env

If multi-site becomes routine, the cleanest path is making site config first-class in `prepare-sdcard.sh` AND adding a `make sdcard SITE=foo` target. Currently the SITE var is environment-only; that's fine for now (you set it once before running prep).
