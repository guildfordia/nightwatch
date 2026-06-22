#!/bin/bash
# Nightwatch — one-command network diagnostic bundle
#
# Collects everything needed to tell hardware/RF limits apart from a real
# software bug, into a single timestamped file the operator can send back.
# Run it ON A NODE, ideally WHILE the problem is happening (peak attendance):
#
#     sudo make diag        # or: sudo scripts/nightwatch-diag.sh
#
# Used by: make diag

set -uo pipefail

# ---- Load env (interface names, mesh IP) ----
NIGHTWATCH_DIR="${NIGHTWATCH_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
ENV_FILE="$NIGHTWATCH_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    # shellcheck source=/dev/null
    set -a; source "$ENV_FILE"; set +a
fi
AP="${AP_IFACE:-wlan2}"          # visitor "Nightwatch" AP (hostapd)
MESH="${MESH_IFACE:-wlan1}"      # 802.11s + batman-adv node-to-node link
SCAN="wlan0"                     # onboard radio, used for RF environment scan

# ---- Output file (persistent dir, easy to scp) ----
DIAG_DIR="$NIGHTWATCH_DIR/diag"
mkdir -p "$DIAG_DIR" 2>/dev/null || DIAG_DIR=/tmp
TS=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo unknown)
OUT="$DIAG_DIR/nw-diag-$(hostname)-$TS.txt"

exec > >(tee "$OUT") 2>&1
sec(){ echo; echo "==================== $1 ===================="; }

sec "IDENTITÉ / HEURE"
hostname; date; uptime
cat /proc/device-tree/model 2>/dev/null | tr -d '\0'; echo

sec "ALIMENTATION / THERMIQUE (throttling matériel)"
echo "get_throttled (0x0 = sain ; bit0=under-voltage, bit3=throttling, bit16+=déjà arrivé):"
vcgencmd get_throttled 2>/dev/null || echo "vcgencmd indisponible"
echo -n "Temp CPU: "; vcgencmd measure_temp 2>/dev/null || awk '{printf "%.1fC\n",$1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "?"
echo "Charge (1/5/15 min):"; cat /proc/loadavg 2>/dev/null
echo "Mémoire:"; free -m 2>/dev/null | head -2

sec "INTERFACES"
ip -br addr 2>/dev/null; echo; ip -br link 2>/dev/null

sec "AP VISITEURS ($AP) — NOMBRE DE CLIENTS CONNECTÉS"
echo -n "Clients connectés en ce moment: "
iw dev "$AP" station dump 2>/dev/null | grep -c '^Station'
echo -n "Limite configurée (max_num_sta): "
grep -h max_num_sta /etc/hostapd*/* /etc/hostapd.conf 2>/dev/null || echo "non définie (limite réelle = CPU/RAM, bien plus basse que le défaut driver)"
echo "--- détail signal/inactivité/erreurs par client ---"
iw dev "$AP" station dump 2>/dev/null | grep -E '^Station|signal:|inactive time:|tx bitrate|tx failed|tx retries'

sec "AP — REJETS / DÉCONNEXIONS (preuve de saturation)"
echo "Comptage des événements hostapd depuis le boot:"
echo -n "  deauth:       "; journalctl -t hostapd -b 2>/dev/null | grep -ciE 'deauth'
echo -n "  disassoc:     "; journalctl -t hostapd -b 2>/dev/null | grep -ciE 'disassoc'
echo -n "  rejets-assoc: "; journalctl -t hostapd -b 2>/dev/null | grep -ciE 'reject|too many|no room|AID'
echo "--- 25 derniers événements bruts ---"
journalctl -t hostapd -b 2>/dev/null | tail -25

sec "MESH ($MESH) — DISTANCE / QUALITÉ DE LIEN NODE-À-NODE"
echo "Canal mesh / puissance:"; iw dev "$MESH" info 2>/dev/null | grep -E 'channel|txpower'
echo "--- voisins 802.11s (signal dBm : >-65 bon, -65..-75 limite, <-80 mauvais) ---"
iw dev "$MESH" station dump 2>/dev/null | grep -E '^Station|signal:|mesh plink:|inactive time:'
echo "--- batman voisins ---"; batctl meshif bat0 n 2>/dev/null
echo "--- batman originators — TQ vers TOUS les nodes (sur 255 : 255=parfait, <150=faible) ---"
batctl meshif bat0 o 2>/dev/null

sec "CONGESTION RADIO ($MESH) — OCCUPATION DU CANAL"
echo "(busy time proche de active time = canal saturé par d'autres réseaux)"
iw dev "$MESH" survey dump 2>/dev/null | grep -A6 'in use'

sec "ENVIRONNEMENT WIFI — RÉSEAUX CONCURRENTS"
ip link set "$SCAN" up 2>/dev/null
# En milieu saturé, 'iw scan' échoue souvent avec "Resource busy (-16)" et ne
# renvoie RIEN. Sans distinction, un scan échoué et un environnement vide
# donnent tous deux 0 réseau — interprétation inverse. On retente quelques
# fois et on garde la sortie ET le code de retour pour les différencier.
SCAN_OUT=""; SCAN_RC=1
for try in 1 2 3; do
    SCAN_OUT=$(iw dev "$SCAN" scan 2>/dev/null); SCAN_RC=$?
    [ $SCAN_RC -eq 0 ] && [ -n "$SCAN_OUT" ] && break
    sleep 2
done
if [ $SCAN_RC -ne 0 ] || [ -z "$SCAN_OUT" ]; then
    echo "Nombre total de réseaux WiFi détectés autour: SCAN ÉCHOUÉ (radio occupée après 3 tentatives) — ce n'est PAS 0 réseau, à reprendre"
else
    echo -n "Nombre total de réseaux WiFi détectés autour: "
    echo "$SCAN_OUT" | grep -c '^BSS'
    echo "Répartition par fréquence (nb de réseaux par canal):"
    echo "$SCAN_OUT" | grep -oE 'freq: [0-9]+' | sort | uniq -c | sort -rn
fi

sec "CARTE DE LA FLOTTE — ADRESSES DES AUTRES NODES"
LOCAL="${MESH_IP%%/*}"
PEER_FILE="/tmp/nightwatch-peers"
echo "Nodes joignables (IP fixe = 192.168.199.10N) :"
for i in $(seq 1 20); do
    ip="192.168.199.$((100 + i))"
    r=$(ping -c1 -W1 "$ip" 2>/dev/null | grep -oE 'time=[^ ]+')
    [ -z "$r" ] && continue
    name=""
    [ -f "$PEER_FILE" ] && name=$(awk -F'|' -v ip="$ip" '$2==ip{print $3}' "$PEER_FILE" 2>/dev/null)
    [ -z "$name" ] && name="nightwatch-$i.local"
    here=""; [ "$ip" = "$LOCAL" ] && here="  <-- CE NODE"
    printf "  %-18s %-22s %s%s\n" "$ip" "$name" "$r" "$here"
done

sec "SERVICES"
for s in nightwatch-mesh ngircd nightwatch-bridge nginx; do
    printf "  %-22s %s\n" "$s" "$(systemctl is-active "$s" 2>/dev/null)"
done
echo "--- erreurs services (20 dernières) ---"
journalctl -p err -b 2>/dev/null | tail -20

sec "ERREURS NOYAU / USB / DRIVER WIFI"
dmesg 2>/dev/null | grep -iE 'mt76|ath9k|usb.*reset|disconnect|firmware|rfkill|cfg80211' | tail -25

# ---- Auto-test fonctionnel ----
# Vérifie que les fonctions clés du node répondent comme attendu. Aide à
# distinguer une config locale incorrecte d'un souci d'environnement radio.
http_code(){ curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || echo "000"; }
verdict(){ # $1=got $2=expected $3=label
    if [ "$1" = "$2" ]; then printf "  [OK]         %-44s got=%s\n" "$3" "$1"
    else                     printf "  [À VÉRIFIER] %-44s got=%s attendu=%s\n" "$3" "$1" "$2"; fi
}

sec "AUTO-TEST FONCTIONNEL"
echo "Légende: [OK]=réponse attendue · [À VÉRIFIER]=écart à examiner"
echo

echo "Captive portal (réponse attendue par chaque OS):"
verdict "$(http_code http://localhost/generate_204)"       "204" "Android /generate_204"
verdict "$(http_code http://localhost/hotspot-detect.html)" "200" "iOS /hotspot-detect.html"
verdict "$(http_code http://localhost/connecttest.txt)"     "200" "Microsoft /connecttest.txt"

echo "Mode d'exploitation:"
MODE="${NIGHTWATCH_MODE:-production}"
echo "  NIGHTWATCH_MODE=$MODE"
if [ "$MODE" = "debug" ]; then
    echo "  [INFO] mode debug actif (via .env) — endpoints de diagnostic ouverts"
else
    verdict "$(http_code http://localhost/api/debug)" "403" "/api/debug fermé en production"
fi

echo "Bandeau d'information du chat:"
if curl -s --max-time 4 http://localhost/ 2>/dev/null | grep -qi 'mailto:'; then
    echo "  [OK]         bandeau + lien de signalement mailto: présents"
else
    echo "  [À VÉRIFIER] bandeau/mailto introuvable dans la page servie"
fi

echo "Cap d'associations par AP:"
MNS=$(grep -h max_num_sta /etc/hostapd*/* /etc/hostapd.conf 2>/dev/null | grep -oE '[0-9]+' | head -1)
verdict "${MNS:-absent}" "8" "hostapd max_num_sta"

echo "Pile chat (ce node):"
verdict "$(http_code http://localhost:3000/health)" "200" "irc-bridge <-> ngircd /health"
echo -n "  voisins batman joignables: "; batctl meshif bat0 n 2>/dev/null | tail -n +3 | grep -c .

echo "DHCP Ethernet (sous-réseau Mac sound 10.0.0.0/24):"
if grep -rhqE '10\.0\.0\.' /etc/dnsmasq.d/* /etc/dnsmasq.conf 2>/dev/null; then
    echo "  [OK]         plage DHCP 10.0.0.0/24 configurée (eth0)"
    BAUX=$(grep -c '10\.0\.0\.' /var/lib/misc/dnsmasq.leases 2>/dev/null || echo 0)
    echo "  baux actifs sur 10.0.0.0/24: $BAUX"
else
    echo "  [À VÉRIFIER] plage 10.0.0.0/24 absente de la conf dnsmasq"
fi

echo "Auto-recovery (journal watchdog, 10 dernières actions):"
journalctl -t nightwatch-watchdog -b 2>/dev/null | tail -10 || echo "  (aucun log watchdog)"

echo "Version de code (à comparer entre nodes — doit être identique partout):"
git -C "$NIGHTWATCH_DIR" describe --tags --always --dirty 2>/dev/null | sed 's/^/  version: /' || echo "  version: inconnue"

echo
echo "============================================================"
echo ">>> Rapport écrit dans : $OUT"
echo ">>> Pour me l'envoyer, depuis TON ordi :"
echo ">>>     scp $(whoami)@$(hostname).local:$OUT ."
echo ">>> Refais 'sudo make diag' sur chaque node listé dans la CARTE DE LA FLOTTE ci-dessus."
echo "============================================================"
