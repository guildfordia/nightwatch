# Captive Portal Cross-OS Test Plan

When a phone or laptop joins the `Nightwatch` SSID, every operating system runs its own connectivity-detection probe to decide whether to pop the captive-portal sheet, show "no internet", or behave normally. Our nginx config already stubs the most common probes, but the actual UX needs to be tested end-to-end on each platform before the next public deployment.

This document is a checklist. Run through it once per platform; record what you observe; fix anything broken.

## What the probes look for

Each OS hits a known URL and expects a specific response. The nginx config in `nginx/nginx.conf` already handles most of these — they redirect or return canned strings. If a probe gets the *expected* answer, the OS thinks "real internet" and *does not* pop the captive portal. If it gets something unexpected (HTTP 200 with non-standard body, or a 302 redirect), the OS pops the captive portal sheet pointing at that redirect or at `dhcp-option=114` if set.

Our captive flow relies on **DNS hijacking** + **dhcp-option=114** — every domain resolves to the local node's mesh IP, and option 114 explicitly points the OS at `http://192.168.199.1/api/captive` (RFC 8908 endpoint). Modern OSes prefer 114; older ones fall back to probe URLs.

| OS | Probe URL | Expected response (real internet) | Our behavior |
|---|---|---|---|
| iOS / iPadOS / macOS | `http://captive.apple.com/hotspot-detect.html` | `<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>` | nginx returns this string verbatim — keeps Apple devices "happy" with no captive popup, but they may not auto-pop the portal either. RFC 8910 dhcp-option=114 is the modern path. |
| Android 11+ | `http://connectivitycheck.gstatic.com/generate_204` | HTTP 204 No Content | nginx redirects (302) — triggers Android to think there's a captive portal, opens NetworkMonitor sheet. |
| Android (legacy) | `http://www.google.com/gen_204` | HTTP 204 | Same redirect handling. |
| Windows 10/11 | `http://www.msftconnecttest.com/connecttest.txt` | `Microsoft Connect Test` | nginx returns this string — Windows shows internet symbol but doesn't pop a captive sheet. Users have to navigate manually. |
| Windows (legacy NCSI) | `http://www.msftncsi.com/ncsi.txt` | `Microsoft NCSI` | Same. |
| Firefox (any OS) | `http://detectportal.firefox.com/canonical.html` | (specific HTML) | Generally hijacked into showing portal sheet. |
| Linux (NetworkManager) | `http://nmcheck.gnome.org/check_network_status.txt` | `NetworkManager is online` | Not currently stubbed — Linux clients see "limited connectivity" sometimes. |

## Test platforms (check off when validated)

For each platform, follow the test procedure below.

- [ ] **iPhone (iOS 16+)** — most common visitor. Settings: forget all networks first.
- [ ] **iPhone (iOS 17+)** — newer CNA behavior, uses RFC 8908 if available.
- [ ] **iPad (iPadOS 16+)** — typically same as iPhone but worth one direct check.
- [ ] **Android (recent Pixel, Android 14+)** — NetworkMonitor, prefers RFC 8908.
- [ ] **Android (Samsung Galaxy, recent firmware)** — historical issues with FT-PSK; basic captive flow should work but verify.
- [ ] **Android (older device, Android 9-10)** — gen_204 fallback, slower probe loop.
- [ ] **macOS (recent)** — CNA window auto-opens.
- [ ] **macOS (CLI / no CNA)** — Safari opens, manual nav.
- [ ] **Windows 11** — taskbar globe icon should change; no popup is expected.
- [ ] **Linux laptop (NetworkManager)** — limited-connectivity icon, manual browser navigation.

## Test procedure (per platform)

### Setup
1. Forget the `Nightwatch` SSID on the device if previously joined.
2. Make sure mobile data is OFF (so all traffic must go via Wi-Fi).
3. Have a stopwatch / timer ready.

### Steps
1. Open Wi-Fi settings on the device.
2. Tap/click `Nightwatch`. Enter PSK if prompted (`Nightwatch`).
3. **Note: time from "associate" to "captive sheet appears"** (target: <5 seconds).
4. Observe what happens, in order:
   - Does the OS show "joining" / "connecting"?
   - Does it briefly show "no internet" or "limited connectivity"?
   - Does a captive portal sheet auto-pop?
   - If yes, what URL is in the address bar of that sheet? Note exactly.
   - Does it show the chat page?
5. If no auto-pop: open a browser (Safari / Chrome / etc.) manually, type `http://chat.nightwatch` or `http://192.168.199.1`, check that page loads.
6. From the chat page: try sending a message. Does it appear back? (if yes: full path works).
7. **Walk between two APs** while connected. Note any visible disruption — chat freezes? messages drop? captive re-pops? page reloads cleanly?
8. **Close the captive sheet without joining**. Does the OS still treat the network as joined? Can you re-pop the sheet from Wi-Fi settings?

### Record per platform

For each platform, fill in:

| Field | Value |
|---|---|
| OS + version | (e.g. iOS 17.2) |
| Time to captive popup | (seconds) |
| Captive popup URL | (exact URL) |
| Page renders correctly | (yes/no, screenshots if no) |
| Chat send/receive works | (yes/no) |
| Roaming behavior | (smooth / brief reconnect / dropped) |
| Anything weird | (free-form notes) |

## Known issues to watch for

- **iOS sometimes refuses to leave "captive mode"**: keeps showing the sheet even after you close it, until you forget+rejoin. Test recovery: forget SSID, rejoin, verify it doesn't loop.
- **Samsung phones with older firmware**: connect but can't reach the chat page. If this happens, check: is FT-PSK enabled? (it shouldn't be by default, but worth verifying — see `docs/phase-c-802.11r-fast-roaming.md`).
- **Android "Sign in to network" hangs**: sometimes the captive sheet loads forever. Workaround: tap the notification, choose "Use this network as is" or similar.
- **macOS Big Sur+ has private Wi-Fi addresses on by default**: each connection uses a different MAC, so you can't recognize the same client across reconnects. Expected behavior; document for testers.
- **Linux laptops show "limited connectivity"**: NetworkManager's probe URL isn't stubbed. Browser navigation works but the icon stays warning-shaped. Consider adding a stub for `nmcheck.gnome.org`.

## Suggested fixes if a platform is broken

- **No captive popup**: check `dhcp-option=114` is actually being handed out (`tcpdump -i br0 'port 67 or 68'` while the phone joins).
- **Captive page won't load**: verify nginx is bound to `192.168.199.1` AND the per-node mesh IP. `ssh nightwatch-2 'ss -tnlp | grep :80'`.
- **Page loads but WebSocket fails**: check origin acceptance in `irc-bridge-go/main.go`. Recent commits made this permissive; if regressed, error is "websocket origin rejected".
- **Page renders but messages don't go through**: ngircd federation issue. Run `mesh-doctor topology` to confirm all nodes are linked.

## When this checklist is mostly green

Update the README's "Compatibility" section listing tested platforms. Cite version numbers tested. Make this a hard requirement before any public deployment: at minimum, current iOS + current Android + current macOS must all show the chat page within 10 seconds of joining.
