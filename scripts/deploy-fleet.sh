#!/bin/bash
# deploy-fleet.sh — generic fleet rollout from station to all Pis.
#
# Replaces the ad-hoc /tmp/deploy-*.sh scripts that accumulated during
# development. Idempotent, dry-run capable, backs up before installing,
# verifies each step, prints a clean per-node summary at the end.
#
# Usage:
#   scripts/deploy-fleet.sh [OPTIONS] FILE [FILE...]
#
# Options:
#   --to PATH          Target directory on the Pi (default: /opt/nightwatch/scripts/)
#   --restart UNITS    Comma-separated systemd units to restart after deploy
#                      (default: none — caller should pass nightwatch-mesh,etc)
#   --nodes LIST       Space-separated node numbers to deploy to
#                      (default: "2 3 4 5 6 7" or $NIGHTWATCH_NODES env var)
#   --dry-run          Only validate locally + show what would happen, don't ship
#   --no-backup        Skip the .bak.<ts> file (default: backup is made)
#
# Example:
#   scripts/deploy-fleet.sh \
#       --to /opt/nightwatch/scripts/ \
#       --restart nightwatch-mesh,nightwatch-discovery \
#       scripts/common.sh scripts/mesh-fix.sh
#
# Prerequisites:
#   - sshpass installed on station (apt-get install -y sshpass)
#   - SSH keys in place: station -> mac-mini (gateway), then -> nightwatch-2
#     and via ProxyJump to peer nodes
#   - User has the Pi sudo password (script prompts once)

set -uo pipefail

NODES=${NIGHTWATCH_NODES:-"2 3 4 5 6 7"}
TARGET_DIR=/opt/nightwatch/scripts/
RESTART_UNITS=""
DRY_RUN=false
DO_BACKUP=true
FILES=()

while [ $# -gt 0 ]; do
  case "$1" in
    --to)        TARGET_DIR="$2"; shift 2 ;;
    --restart)   RESTART_UNITS="$2"; shift 2 ;;
    --nodes)     NODES="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --no-backup) DO_BACKUP=false; shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# *//'
      exit 0 ;;
    --) shift; FILES+=("$@"); break ;;
    -*) echo "unknown flag: $1"; exit 2 ;;
    *)  FILES+=("$1"); shift ;;
  esac
done

[ ${#FILES[@]} -eq 0 ] && { echo "no files to deploy. see --help"; exit 2; }

# Local validation: every file exists + bash/python syntax checks
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "missing: $f"; exit 2; }
  case "$f" in
    *.sh|*.bash) bash -n "$f" || { echo "bash syntax: $f"; exit 2; } ;;
    *.py)        python3 -m py_compile "$f" || { echo "py syntax: $f"; exit 2; } ;;
  esac
done
echo "[ok] local validation: ${#FILES[@]} file(s)"

if $DRY_RUN; then
  echo "[dry-run] would deploy these files to ${TARGET_DIR} on nodes: ${NODES}"
  printf '  %s\n' "${FILES[@]}"
  [ -n "$RESTART_UNITS" ] && echo "  then restart: $RESTART_UNITS"
  exit 0
fi

# SSH plumbing
JUMP=nightwatch-2.local
SSH_OPTS=(-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)

read -rsp "Pi sudo password (paste OK): " PIPASS
echo
[ -z "$PIPASS" ] && { echo "empty password — abort"; exit 2; }

target_for() {
  local n=$1
  if [ "$n" = "2" ]; then
    echo "user@nightwatch-2.local"
  else
    echo "user@192.168.199.10$n"
  fi
}
needs_jump() { [ "$1" != "2" ]; }

ok=0; fail=0
for n in $NODES; do
  echo "=== node $n ==="
  TARGET=$(target_for "$n")
  SCP_EXTRA=()
  SSH_EXTRA=()
  if needs_jump "$n"; then
    SCP_EXTRA=(-o "ProxyJump=$JUMP")
    SSH_EXTRA=(-o "ProxyJump=$JUMP")
  fi

  # 1) Ship files to /tmp on the Pi
  if ! scp "${SSH_OPTS[@]}" "${SCP_EXTRA[@]}" "${FILES[@]}" "$TARGET:/tmp/" >/dev/null; then
    echo "  [FAIL] scp"; fail=$((fail+1)); continue
  fi
  echo "  [ok] scp ${#FILES[@]} file(s)"

  # 2) Remote validate, backup, install, restart
  REMOTE_PIPASS=$(printf %q "$PIPASS")
  REMOTE_TARGET=$(printf %q "$TARGET_DIR")
  REMOTE_RESTART=$(printf %q "$RESTART_UNITS")
  REMOTE_BACKUP=$DO_BACKUP
  REMOTE_NAMES=$(printf %q "$(printf '%s\n' "${FILES[@]##*/}")")

  if ! ssh "${SSH_OPTS[@]}" "${SSH_EXTRA[@]}" "$TARGET" \
        "PIPASS=$REMOTE_PIPASS TARGET_DIR=$REMOTE_TARGET RESTART_UNITS=$REMOTE_RESTART DO_BACKUP=$REMOTE_BACKUP NAMES=$REMOTE_NAMES bash -s" <<'REMOTE'
set -u
TS=$(date +%Y%m%d-%H%M%S)
fail=0

while IFS= read -r name; do
  [ -z "$name" ] && continue
  src="/tmp/$name"
  dest="${TARGET_DIR%/}/$name"
  # Remote syntax recheck (cheap, catches mid-flight corruption)
  case "$name" in
    *.sh|*.bash) bash -n "$src" || { echo "  [FAIL] remote bash -n $name"; rm -f "$src"; fail=1; continue; } ;;
    *.py)        python3 -m py_compile "$src" || { echo "  [FAIL] remote py_compile $name"; rm -f "$src"; fail=1; continue; } ;;
  esac
  # Backup if dest exists
  if [ "$DO_BACKUP" = "true" ] && sudo -n test -f "$dest"; then
    echo "$PIPASS" | sudo -S cp "$dest" "$dest.bak.$TS" 2>/dev/null
  fi
  # Install (root-owned, executable for shell scripts)
  mode=0644
  case "$name" in *.sh|*.bash|*.py) mode=0755 ;; esac
  if ! echo "$PIPASS" | sudo -S install -m "$mode" -o root -g root "$src" "$dest" 2>/dev/null; then
    echo "  [FAIL] install $name"
    fail=1
  else
    echo "  [ok] $name -> $dest (mode $mode)"
  fi
  rm -f "$src"
done <<< "$NAMES"

# Restart units if specified, comma-separated
if [ -n "$RESTART_UNITS" ] && [ $fail -eq 0 ]; then
  IFS=',' read -ra UNITS <<< "$RESTART_UNITS"
  for u in "${UNITS[@]}"; do
    sudo -n systemctl restart "$u" 2>&1 | tail -1
    sleep 2
    if sudo -n systemctl is-active "$u" >/dev/null 2>&1; then
      echo "  [ok] restarted $u (active)"
    else
      echo "  [WARN] $u not active after restart"
      fail=1
    fi
  done
fi
exit $fail
REMOTE
  then
    fail=$((fail+1)); echo "  [FAIL] remote step on node $n"
    continue
  fi
  ok=$((ok+1))
done

echo
echo "=== deploy summary: $ok ok, $fail fail ==="
[ $fail -gt 0 ] && exit 1
exit 0
