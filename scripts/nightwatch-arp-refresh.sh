#!/bin/bash
# Nightwatch — gratuitous ARP refresh on station association.
#
# Invoked by `hostapd_cli -a`. On every AP-STA-CONNECTED, broadcast a
# gratuitous ARP for the shared service IP 192.168.199.1 with this node's
# br0 MAC, so the station's ARP cache learns the local responder
# immediately. Without this, a station that roamed from another node keeps
# the previous node's br0 MAC cached, causing packets to either trombone
# via bat0 (wasted air time) or black-hole entirely until the entry expires
# (1–2 min on most phones) when the previous node is offline.
#
# This is the pragmatic half-measure for the shared service IP anchoring
# strategy. The full design (shared anchor MAC via macvlan + ebtables)
# remains a High Priority TODO in the README. This script preserves
# session continuity at small scale; the full anchor MAC is what unlocks
# the capacity ceiling by eliminating cross-node trombones at 40+ users.
#
# The companion ebtables rule installed by scripts/mesh-fix.sh drops any
# ARP for 192.168.199.1 leaking onto bat0 — without it, our gratuitous ARP
# would corrupt every other node's STA caches and confuse batman-adv DAT.

set -u

EVENT="${2:-}"
STA_MAC="${3:-}"

[ "$EVENT" = "AP-STA-CONNECTED" ] || exit 0

# Debounce per STA MAC: at most one ARP burst every 2 s. Cheap protection
# against storms during rapid re-association loops.
if [ -n "$STA_MAC" ]; then
    DEBOUNCE_DIR=/run/nightwatch-arp
    mkdir -p "$DEBOUNCE_DIR"
    STAMP="$DEBOUNCE_DIR/$STA_MAC"
    now=$(date +%s)
    if [ -r "$STAMP" ]; then
        last=$(cat "$STAMP" 2>/dev/null || echo 0)
        [ "$((now - last))" -lt 2 ] && exit 0
    fi
    echo "$now" > "$STAMP"
fi

arping -c 2 -I br0 -U 192.168.199.1 >/dev/null 2>&1 || true
exit 0
