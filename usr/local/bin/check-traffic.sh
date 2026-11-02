#!/bin/bash
CONF="/etc/monitor-ports.conf"
TVH_USER="{{TVH_USER}}"
TVH_PASSWORD="{{TVH_PASSWORD}}"

# Jellyfin (opzionale): se JELLYFIN_API_KEY è vuota il controllo viene saltato.
# Su Fedora: impostarla con un drop-in systemd (Environment=JELLYFIN_API_KEY=...)
# Su NixOS: viene passata tramite environmentFile del modulo.
JELLYFIN_URL="${JELLYFIN_URL:-http://localhost:8096}"
JELLYFIN_API_KEY="${JELLYFIN_API_KEY:-}"

# 1. CONTROLLO STAMPANTE
IS_PRINTING=$(curl -s \
  "http://localhost/printer/objects/query?print_stats" |
  grep -c '"state":"printing"')

if [ "$IS_PRINTING" -gt 0 ]; then
  echo "Printer printing: Suspension locked."
  exit 0
fi

# 2. CONTROLLO TV IN RIPRODUZIONE
IS_STREAMING=$(curl -s \
  "http://$TVH_USER:$TVH_PASSWORD@localhost:9981/api/status/connections" |
  grep -c '"streaming":1')

if [ "$IS_STREAMING" -gt 0 ]; then
  echo "TV playing: Suspension locked."
  exit 0
fi

# 3. CONTROLLO FILE SAMBA APERTI
# Usa smbstatus invece di ss per evitare falsi positivi da keepalive KIO/Dolphin
SAMBA_FILES=$(smbstatus --locked 2>/dev/null | grep -c ".")

if [ "$SAMBA_FILES" -gt 0 ]; then
  echo "Open Samba files ($SAMBA_FILES). Suspension locked."
  exit 0
fi

# 4. CONTROLLO JELLYFIN IN RIPRODUZIONE (API /Sessions)
# Una sessione conta solo se sta riproducendo qualcosa e non è in pausa.
# La porta 8096 va marcata !wol-only in monitor-ports.conf: serve solo al WOL.
if [ -n "$JELLYFIN_API_KEY" ]; then
  JELLYFIN_PLAYING=$(curl -s --max-time 5 \
    -H "X-Emby-Token: $JELLYFIN_API_KEY" \
    "$JELLYFIN_URL/Sessions" |
    jq '[.[] | select(.NowPlayingItem != null and .PlayState.IsPaused != true)] | length' 2>/dev/null)

  if [ "${JELLYFIN_PLAYING:-0}" -gt 0 ]; then
    echo "Jellyfin playing ($JELLYFIN_PLAYING sessions): Suspension locked."
    exit 0
  fi
fi

# 5. CONTROLLO CONNESSIONI ATTIVE SULLE ALTRE PORTE MONITORATE
# Le porte vengono lette da monitor-ports.conf (escluse quelle marcate !wol-only,
# come Samba e tvheadend, gestite dai controlli specifici sopra).
PORTS=$(grep -v 'wol-only' "$CONF" 2>/dev/null |
  sed 's/#.*//' | grep -Eo '[0-9]+' | paste -sd'|' -)

if [ -n "$PORTS" ]; then
  ACTIVE=$(ss -tn state established | grep -cE ":($PORTS) ")

  if [ "$ACTIVE" -gt 0 ]; then
    echo "Active connections detected ($ACTIVE). Suspension locked."
    exit 0
  fi
fi

# 6. NESSUNA ATTIVITÀ — SOSPENSIONE
# Dopo la pausa di 60 secondi tutti i controlli vengono rifatti da capo
# (l'script si rilancia): se nel frattempo qualcosa è tornato attivo, uno dei
# controlli sopra esce senza sospendere.
if [ -z "$AUTOSUSWOL_RECHECK" ]; then
  echo "No activity detected. Rechecking in 60 seconds...."
  sleep 60
  AUTOSUSWOL_RECHECK=1 exec "$0"
fi

echo "Still no activity after the grace period. Suspending."
systemctl suspend
