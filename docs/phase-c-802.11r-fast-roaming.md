# Phase C — 802.11r Fast Roaming

**Status:** designed, NOT applied. Depends on `generate_hostapd_conf` (currently in working-copy WIP, not in `origin/main`). Apply once your WIP is merged.

**Companion to:** Phase A (anycast service IP) + Phase B (gratuitous ARP) on branch `feat/seamless-roaming`. Anycast handles L3 continuity; 802.11r handles L2 fast handoff. Both together = seamless roaming.

## Why gate behind an env flag

Your existing WIP comment in `generate_hostapd_conf`:

> WPA-PSK only by default. FT-PSK (802.11r) enables fast roaming but some Samsung phones reject it.

That's load-bearing context. Some Samsung firmware refuses to associate with APs offering FT-PSK in the RSN IE. Specifically, certain Galaxy S8/S9-era and some 2023 Samsung firmware revisions drop FT-PSK with no error message — phone shows "couldn't connect to network" until you remove FT-PSK from `wpa_key_mgmt`.

So 802.11r should be **opt-in via env flag**, not enabled by default. Default off = same behavior as today; flip `ENABLE_FT=true` in `.env` for a known-safe-audience demo.

## Required changes

### 1. `.env.example` — add the gate

Add near the top:

```sh
# Enable 802.11r Fast Transition (seamless WiFi roaming between AP nodes).
# Cuts L2 handoff from 1-3s to 50-150ms. NOTE: some Samsung firmware rejects
# FT-PSK and refuses to associate at all. Leave false unless you know your
# audience is FT-tolerant (most modern iPhones, Pixels, recent Android are fine).
ENABLE_FT=false
```

### 2. `scripts/common.sh` — replace the hostapd template body

In `generate_hostapd_conf`, the current commented-out block needs to become an actual `if [ "$ENABLE_FT" = "true" ]` switch with proper `r0kh`/`r1kh` lists. Here's the replacement for the current `# WPA2-PSK + 802.11r Fast Transition` section through end of file:

```bash
    # WPA2-PSK (always on) — base authentication
    cat >> "$conf_path" << HAPEOF
wpa=2
wpa_passphrase=$password
wpa_pairwise=CCMP
rsn_pairwise=CCMP
HAPEOF

    if [ "${ENABLE_FT:-false}" = "true" ]; then
        # 802.11r Fast Transition: clients pre-authenticate to neighbor APs and
        # roam without a full 4-way handshake. Requires consistent
        # mobility_domain across all nodes, plus matching r0kh/r1kh entries
        # listing every AP's MAC + nas_identifier + shared key.
        #
        # The shared 128-bit key (FT_SHARED_KEY) must be IDENTICAL on every
        # node and high-entropy. Generate once with: openssl rand -hex 16
        # Set in .env on every node before regenerating hostapd.conf.
        local ft_key="${FT_SHARED_KEY:?FT_SHARED_KEY required when ENABLE_FT=true}"
        local mob_dom="${MOBILITY_DOMAIN:-4e57}"  # any 4-hex; same on all nodes

        cat >> "$conf_path" << FTEOF
# Fast Transition (802.11r)
wpa_key_mgmt=WPA-PSK FT-PSK
mobility_domain=$mob_dom
nas_identifier=node$node_num
ft_psk_generate_local=0
ft_over_ds=0
pmk_r1_push=1
reassociation_deadline=20000
r0_key_lifetime=10000
FTEOF

        # r0kh/r1kh lists: one entry per OTHER node in the fleet. Each entry
        # maps that node's wlan2 BSSID + nas_identifier to the shared key.
        # We don't know other nodes' BSSIDs at config-gen time, so use the
        # wildcard form (00:00:00:00:00:00) which means "any peer with a
        # matching nas_identifier and key". Less strict but functional.
        local n
        for n in $(seq 1 "$MAX_NODES"); do
            [ "$n" = "$node_num" ] && continue
            cat >> "$conf_path" << RKHEOF
r0kh=00:00:00:00:00:00 node$n $ft_key
r1kh=00:00:00:00:00:00 00:00:00:00:00:00 $ft_key
RKHEOF
        done
    else
        cat >> "$conf_path" << NOFTEOF
wpa_key_mgmt=WPA-PSK
NOFTEOF
    fi

    cat >> "$conf_path" << ENDEOF
# 802.11n capabilities
wmm_enabled=1

# Control interface for hostapd_cli
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
ENDEOF
}
```

(Adjust the surrounding `cat >> "$conf_path"` heredoc structure to match what your WIP has — the key change is splitting the WPA-PSK base from the optional FT block and adding the `r0kh`/`r1kh` loop.)

### 3. Generate the shared key once, deploy fleet-wide

Run on station once:

```sh
openssl rand -hex 16
```

Add to **every node's** `.env` (consistent value):

```sh
FT_SHARED_KEY=<the hex string from above>
MOBILITY_DOMAIN=4e57
ENABLE_FT=false  # flip to true when you're ready to test
```

### 4. Deploy + test sequence

1. With `ENABLE_FT=false` everywhere, push the new `common.sh` + `.env` updates. Regenerate `hostapd.conf` on each node, restart hostapd. Verify normal connectivity is unaffected — this is your safe baseline.
2. **Test 802.11r on ONE node first.** Set `ENABLE_FT=true` only on (e.g.) `nightwatch-2`, regenerate its hostapd.conf, restart hostapd on that node only. Try connecting with your test phones. Watch for any phone that fails to associate — that's a Samsung-style FT incompatibility, abort and stay at false.
3. If the single-node test is clean, flip `ENABLE_FT=true` on the remaining 5 nodes, regenerate + restart hostapd on each. Now roaming between them benefits from FT.
4. Roam test: walk between two APs while watching ping latency from the phone. With FT working you should see ~50-150ms gaps instead of 1-3s.

## Rollback

If anything breaks: set `ENABLE_FT=false`, regenerate hostapd.conf, restart hostapd. Returns to plain WPA2-PSK in seconds.

## What 802.11r doesn't fix

- **Unplanned node death** — phone still has to *detect* the dead AP via beacon timeout (1-5s, governed by 802.11 standard). Once detected, FT does help reauth quickly to a peer AP, but the detection window itself is not shortened.
- **Application-layer state** — WebSocket still drops during the 50-150ms handoff. Reconnect happens fast but momentarily visible. The chat replay buffer covers it.
- **First-time association** — FT only helps *roams*. The very first connect is full WPA2 4-way handshake.

For unplanned-death detection: the right tool is **802.11v BSS Transition Management** — a separate, complementary feature where a node about to die sends an explicit "go connect to AP B" disassoc-imminent frame. Phones supporting 802.11v honor it and pre-emptively switch. Not in scope for Phase C; consider for a later iteration if you want sub-second failover.
