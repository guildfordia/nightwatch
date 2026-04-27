# Node numbering — why it works the way it does

Each Nightwatch Pi has a `PI_NUMBER` (1-20) that determines its mesh IP, DHCP range, IRC server name, and hostname. This document explains how that number is assigned and why we don't use simpler schemes that look more elegant on paper.

## TL;DR — three paths in priority order

1. **Prep-time assignment (preferred)**: `scripts/prepare-sdcard.sh` writes the chosen number to `/opt/nightwatch/.node-number` with a `FIXED` marker on the second line. This is committed at SD-card creation and survives every reboot. The registry of taken numbers is at `.node-registry` (gitignored).
2. **Saved-from-previous-boot**: if no `FIXED` marker but `.node-number` exists, that number is reused. A lightweight check on each subsequent boot compares the saved number against the MAC-sort-based position from `batctl meshif bat0 n`, and reassigns if they disagree.
3. **First-boot scan**: if `.node-number` doesn't exist (fresh image, manual install), `scan_mesh` discovers other nodes via 802.11s, then picks the lowest unassigned number.

Path 1 is what production deployments use. Path 3 is the rough-around-the-edges cold-boot path.

## Schemes considered and rejected

### MAC-hash (rejected)

Take SHA-256 of the wlan1 MAC, modulo `MAX_NODES`, plus 1. Looks elegant — fully deterministic from hardware, no scan needed.

**Why rejected**: with `MAX_NODES = 20` and 6-10 actual deployed nodes, the birthday-paradox collision probability is ~30-50%. When two nodes hash to the same number, you'd still need conflict resolution — so the scheme adds complexity without removing it. Worse, the collision happens *quietly* at boot rather than visibly during SD prep.

If `MAX_NODES` were 1000+, MAC-hash would be safe. With 20 slots it's not.

### Pure scan-and-pick (rejected as primary path)

Boot, join mesh, observe other MACs, pick a position. This is path 3 above.

**Why rejected as the *only* path**: cold boot with N Pis simultaneously powering on means all N might decide they're "node 1" before they hear each other. There's a random delay to mitigate this (1-5s, see line 379) but it's not deterministic and has shipped real conflict-resolution races in the past.

### Centralized assignment server (rejected)

A node calls a registry service to get its number. Industry-standard for cluster systems.

**Why rejected**: requires that registry service to exist and be reachable. For an art-piece deployment that should run from a cold boot in a venue with no DHCP server, no internet, and possibly no station, the dependency makes the whole thing brittle.

## Why prep-time assignment wins

`prepare-sdcard.sh` runs on station, where you know:
- Which physical SD card you're writing
- Which slot in the fleet it's filling
- The current registry of taken numbers

That's the right place to commit the decision. The Pi just reads the file at boot and trusts it. Conflict resolution becomes a degenerate case — only triggered when someone manually copies an SD card or skips `prepare-sdcard.sh`.

## The lightweight conflict check (path 2)

Even with `FIXED`, there's one edge case: if you swap two SD cards between physical Pis (or move a card between mesh segments), the saved number could be wrong for the new mesh position. The check at lines 357-372 of `nodeconfig.sh` handles this:

- Compute MAC-sort position: where does our wlan1 MAC fall in the sorted list of (us + batman neighbors)?
- If that doesn't match `.node-number`, log the conflict, reassign to MAC-sort position.

This is **only runs when FIXED is unset** — production deployments skip this check entirely (their assignment is authoritative).

## What to change if you redeploy

If you reflash an SD card and want to give it a different node number:

```sh
# On station, before flashing:
scripts/prepare-sdcard.sh SD=/dev/diskX NODE=N
# This writes both the .node-number FIXED marker AND updates .node-registry
```

Don't manually edit `.node-number` after deployment unless you also clear the FIXED marker — otherwise the running mesh-doctor's view will diverge from the Pi's self-reported number.
