#!/bin/bash
TVH_USER="odino"
TVH_PASSWORD="presoter1"

# 1. CONTROLLO STAMPANTE
IS_PRINTING=$(curl -s \
  "http://localhost/printer/objects/query?print_stats" |
  grep -c '"state":"printing"')

if [ "$IS_PRINTING" -gt 0 ]; then
  echo "Stampante in stampa: sospensione bloccata."
  exit 0
fi

# 2. CONTROLLO TV IN RIPRODUZIONE
IS_STREAMING=$(curl -s \
  "http://$TVH_USER:$TVH_PASSWORD@localhost:9981/api/status/connections" |
  grep -c '"streaming":1')

if [ "$IS_STREAMING" -gt 0 ]; then
  echo "TV in riproduzione: sospensione bloccata."
  exit 0
fi

# 3. CONTROLLO CONNESSIONI ATTIVE SULLE PORTE MONITORATE
ACTIVE=$(ss -tn state established | grep -cE ":(80|445|7125|9000|9090) ")

if [ "$ACTIVE" -gt 0 ]; then
  echo "Connessioni attive rilevate ($ACTIVE). Sospensione bloccata."
  exit 0
fi

# 4. NESSUNA ATTIVITÀ — SOSPENSIONE
echo "Nessuna attività rilevata. Sospensione tra 60 secondi..."
sleep 60
systemctl suspend
