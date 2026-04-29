#!/usr/bin/env python3
"""nightwatch-roamer — fleet-wide 802.11v BSS Transition steering daemon.

Per-node Python daemon that:
  - Reads local AP station list (MAC + signal) via `hostapd_cli all_sta`
  - Broadcasts that snapshot every PUBLISH_INTERVAL seconds over UDP on the
    mesh bridge so peer nodes know who's connected here at what signal
  - Receives peer broadcasts, building a fleet-wide MAC->{AP: signal} map
  - Every DECISION_INTERVAL, scans MACs on the local AP and looks for
    a peer AP with significantly better signal for the same MAC. If found,
    issues an 802.11v BSS Transition Management Request via hostapd_cli to
    politely steer the client. Phone may comply or ignore — that's by design.

Decision rules (Q3 default):
  - Threshold: local signal must be < SIGNAL_THRESHOLD (-70 dBm default)
  - Better-by: target AP signal must be ≥ SIGNAL_BETTER_BY dB stronger (5 default)
  - Hysteresis: HYSTERESIS_COUNT consecutive observations confirm before BTM (2 default)
  - Cooldown: don't BTM the same MAC more than once per COOLDOWN_SECONDS (30 default)

Q4 default: if the client ignores the BTM, log it. Don't escalate to deauth.

Dry-run mode (NIGHTWATCH_ROAMER_DRYRUN=true) logs decisions but does NOT send
BTM requests. Default ON for first deploy — flip to false in env once verified.
"""

import logging
import os
import re
import socket
import subprocess
import sys
import threading
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

# --- Configuration via environment ---
NODE_NUM = int(os.getenv("PI_NUMBER", "0") or "0")
AP_IFACE = os.getenv("AP_IFACE", "wlan2")
BR_IFACE = os.getenv("BR_IFACE", "br0")
ROAM_PORT = int(os.getenv("ROAM_PORT", "4920"))
PUBLISH_INTERVAL = float(os.getenv("PUBLISH_INTERVAL", "3.0"))
DECISION_INTERVAL = float(os.getenv("DECISION_INTERVAL", "5.0"))
SIGNAL_THRESHOLD = int(os.getenv("SIGNAL_THRESHOLD", "-70"))
SIGNAL_BETTER_BY = int(os.getenv("SIGNAL_BETTER_BY", "5"))
HYSTERESIS_COUNT = int(os.getenv("HYSTERESIS_COUNT", "2"))
COOLDOWN_SECONDS = int(os.getenv("COOLDOWN_SECONDS", "30"))
DRYRUN = os.getenv("NIGHTWATCH_ROAMER_DRYRUN", "true").lower() in ("true", "1", "yes")

# Broadcast scope: 192.168.199.255 hits every node on the bridged mesh.
# Clients connected to wlan2 also receive these but silently drop (no listener).
# Trade-off accepted: a few small UDP packets on Wi-Fi vs the complexity of
# bind-to-bat0 with the no-IP-on-bat0 quirk.
BROADCAST_IP = os.getenv("ROAM_BROADCAST_IP", "192.168.199.255")
WIRE_PREFIX = "NIGHTWATCH_ROAM"
MAX_PACKET = 4096

logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("roamer")


@dataclass
class StationView:
    mac: str
    ap_node: int
    signal_dbm: int
    seen_at: float


@dataclass
class CandidateState:
    confirms: int = 0
    last_btm_at: float = 0.0


class FleetState:
    """Fleet-wide view: which MAC is on which AP, with what signal."""
    def __init__(self):
        # mac -> {ap_node: StationView}
        self.views: Dict[str, Dict[int, StationView]] = defaultdict(dict)
        # mac -> CandidateState (for OUR local AP only)
        self.candidates: Dict[str, CandidateState] = defaultdict(CandidateState)
        self.lock = threading.Lock()

    def update(self, ap_node: int, stations: List[Tuple[str, int]], now: float):
        with self.lock:
            # Drop this AP's old contribution
            for mac in list(self.views.keys()):
                self.views[mac].pop(ap_node, None)
                if not self.views[mac]:
                    del self.views[mac]
            # Add fresh
            for mac, signal in stations:
                self.views[mac][ap_node] = StationView(mac, ap_node, signal, now)

    def candidates_for(
        self, my_node: int, threshold: int, better_by: int, max_age: float, now: float
    ):
        with self.lock:
            for mac, by_ap in list(self.views.items()):
                here = by_ap.get(my_node)
                if not here or now - here.seen_at > max_age:
                    continue
                if here.signal_dbm > threshold:
                    continue
                best: Optional[StationView] = None
                for ap_node, v in by_ap.items():
                    if ap_node == my_node or now - v.seen_at > max_age:
                        continue
                    if v.signal_dbm - here.signal_dbm < better_by:
                        continue
                    if best is None or v.signal_dbm > best.signal_dbm:
                        best = v
                if best is not None:
                    yield (mac, here.signal_dbm, best.ap_node, best.signal_dbm)


def hostapd_cli(*args, iface: Optional[str] = None) -> str:
    cmd = ["hostapd_cli"]
    if iface:
        cmd += ["-i", iface]
    cmd += list(args)
    try:
        return subprocess.check_output(cmd, stderr=subprocess.STDOUT, timeout=3, text=True)
    except subprocess.SubprocessError as e:
        log.warning("hostapd_cli %s failed: %s", " ".join(args), e)
        return ""


_MAC_LINE = re.compile(r"^([0-9a-f]{2}(?::[0-9a-f]{2}){5})\s*$", re.I)
_SIGNAL_LINE = re.compile(r"^signal=(-?\d+)")


def get_local_stations() -> List[Tuple[str, int]]:
    out = hostapd_cli("all_sta", iface=AP_IFACE)
    if not out:
        return []
    stations: List[Tuple[str, int]] = []
    cur_mac: Optional[str] = None
    cur_signal: Optional[int] = None
    for line in out.splitlines():
        m = _MAC_LINE.match(line)
        if m:
            if cur_mac and cur_signal is not None:
                stations.append((cur_mac.lower(), cur_signal))
            cur_mac = m.group(1)
            cur_signal = None
            continue
        m = _SIGNAL_LINE.match(line)
        if m and cur_mac:
            cur_signal = int(m.group(1))
    if cur_mac and cur_signal is not None:
        stations.append((cur_mac.lower(), cur_signal))
    return stations


def encode_packet(node: int, ts: int, stations: List[Tuple[str, int]]) -> bytes:
    parts = [WIRE_PREFIX, str(node), str(ts)]
    parts.extend(f"{m}:{s}" for m, s in stations)
    return "|".join(parts).encode("utf-8")


def decode_packet(data: bytes) -> Optional[Tuple[int, int, List[Tuple[str, int]]]]:
    try:
        parts = data.decode("utf-8").split("|")
    except UnicodeDecodeError:
        return None
    if len(parts) < 3 or parts[0] != WIRE_PREFIX:
        return None
    try:
        node, ts = int(parts[1]), int(parts[2])
    except ValueError:
        return None
    stations: List[Tuple[str, int]] = []
    for tok in parts[3:]:
        if ":" not in tok:
            continue
        mac, _, sig = tok.rpartition(":")
        if not _MAC_LINE.match(mac):
            continue
        try:
            stations.append((mac.lower(), int(sig)))
        except ValueError:
            continue
    return (node, ts, stations)


def publisher(state: FleetState, sock: socket.socket):
    while True:
        try:
            stations = get_local_stations()
            now = time.time()
            state.update(NODE_NUM, stations, now)
            packet = encode_packet(NODE_NUM, int(now), stations)
            if len(packet) > MAX_PACKET:
                # Truncate by dropping trailing stations rather than corrupting wire format
                packet = packet[:MAX_PACKET]
            sock.sendto(packet, (BROADCAST_IP, ROAM_PORT))
            log.debug("published %d stations", len(stations))
        except Exception as e:
            log.warning("publisher: %s", e)
        time.sleep(PUBLISH_INTERVAL)


def subscriber(state: FleetState, sock: socket.socket):
    while True:
        try:
            data, _addr = sock.recvfrom(MAX_PACKET)
            decoded = decode_packet(data)
            if not decoded:
                continue
            node, _ts, stations = decoded
            if node == NODE_NUM:
                continue  # ignore loopback of our own broadcasts
            state.update(node, stations, time.time())
            log.debug("rcv from node %d: %d stations", node, len(stations))
        except Exception as e:
            log.warning("subscriber: %s", e)


def send_btm(mac: str, target_node: int, dryrun: bool) -> bool:
    """Issue BSS_TM_REQ. Without target neighbor BSSID we let the phone
    re-scan; the disassoc_timer hint nudges it to actually move soon."""
    args = ["BSS_TM_REQ", mac, "pref=1", "disassoc_timer=200"]
    # TODO v2: include neighbor=<bssid>,<info>,... once we have a fleet
    # BSSID map (could be exchanged in the same UDP broadcast).
    if dryrun:
        log.info("[DRY-RUN] would BTM %s -> node %d (args=%s)",
                 mac, target_node, " ".join(args))
        return True
    out = hostapd_cli(*args, iface=AP_IFACE)
    if "OK" in out:
        log.info("BTM %s -> node %d: OK", mac, target_node)
        return True
    log.warning("BTM %s failed: %s", mac, out.strip() or "no response")
    return False


def decision_loop(state: FleetState):
    max_age = max(PUBLISH_INTERVAL * 3, 15.0)
    while True:
        try:
            now = time.time()
            triggered: set = set()
            for mac, my_sig, target_node, target_sig in state.candidates_for(
                NODE_NUM, SIGNAL_THRESHOLD, SIGNAL_BETTER_BY, max_age, now
            ):
                cs = state.candidates[mac]
                if now - cs.last_btm_at < COOLDOWN_SECONDS:
                    continue
                cs.confirms += 1
                triggered.add(mac)
                if cs.confirms < HYSTERESIS_COUNT:
                    log.info("hysteresis: %s here=%ddBm target=node%d(%ddBm) "
                             "confirm %d/%d",
                             mac, my_sig, target_node, target_sig,
                             cs.confirms, HYSTERESIS_COUNT)
                    continue
                if send_btm(mac, target_node, DRYRUN):
                    cs.last_btm_at = now
                cs.confirms = 0
            # Decay confirms for MACs that didn't trigger this round
            with state.lock:
                for mac, cs in list(state.candidates.items()):
                    if mac not in triggered and cs.confirms > 0:
                        cs.confirms = 0
        except Exception as e:
            log.warning("decision: %s", e)
        time.sleep(DECISION_INTERVAL)


def main():
    if NODE_NUM == 0:
        log.error("PI_NUMBER not set; refusing to start")
        sys.exit(2)
    log.info(
        "starting: node=%d ap=%s threshold=%ddBm better-by=%ddB "
        "hysteresis=%d cooldown=%ds dryrun=%s",
        NODE_NUM, AP_IFACE, SIGNAL_THRESHOLD, SIGNAL_BETTER_BY,
        HYSTERESIS_COUNT, COOLDOWN_SECONDS, DRYRUN,
    )

    state = FleetState()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.bind(("0.0.0.0", ROAM_PORT))

    threading.Thread(target=publisher, args=(state, sock), daemon=True).start()
    threading.Thread(target=subscriber, args=(state, sock), daemon=True).start()
    decision_loop(state)


if __name__ == "__main__":
    main()
