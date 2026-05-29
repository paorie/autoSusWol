#!/bin/bash

FILE_STAT="/tmp/traffic_stat"
TVH_USER="odino"
TVH_PASSWORD="presoter1"
 
# 1. CONTROLLO STAMPANTE
IS_PRINTING=$(curl -s \
    "http://localhost/printer/objects/query?print_stats" \
    | grep -c '"state":"printing"')
 
if [ "$IS_PRINTING" -gt 0 ]; then
    echo "Stampante in stampa: sospensione bloccata."
    exit 0
fi
 
# 2. CONTROLLO TV IN RIPRODUZIONE
IS_STREAMING=$(curl -s \
    "http://$TVH_USER:$TVH_PASSWORD@localhost:9981/api/status/connections" \
    | grep -c '"streaming":1')
 
if [ "$IS_STREAMING" -gt 0 ]; then
    echo "TV in riproduzione: sospensione bloccata."
    exit 0
fi
 
# 3. RECUPERO DATI TRAFFICO (somma bytes da tutti i counter)
#TOTAL_BYTES=$(nft list table inet traffic_monitor 2>/dev/null \
#    | grep "counter packets" \
#    | awk '{for(i=1;i<=NF;i++) if($i=="bytes") print $(i+1)}' \
#    | awk '{sum+=$1} END {print sum+0}')

TOTAL_BYTES=$(nft list counter inet traffic_monitor total_traffic 2>/dev/null | \
    grep -oP 'bytes \K[0-9]+' || echo 0)

# 4. GESTIONE FILE STATO
if [ ! -f "$FILE_STAT" ]; then
    echo "$TOTAL_BYTES" > "$FILE_STAT"
    exit 0
fi
 
LAST_BYTES=$(cat "$FILE_STAT")
 
# 5. LOGICA DI CONFRONTO
if [ "$TOTAL_BYTES" -gt "$LAST_BYTES" ]; then
    echo "$TOTAL_BYTES" > "$FILE_STAT"
    echo "Attività rilevata: $TOTAL_BYTES bytes"
    exit 0
elif [ "$TOTAL_BYTES" -lt "$LAST_BYTES" ]; then
    # Contatori resettati (reboot server)
    echo "$TOTAL_BYTES" > "$FILE_STAT"
    echo "Reset contatori. Allineamento a $TOTAL_BYTES"
    exit 0
else
    echo "Nessuna attività ($TOTAL_BYTES bytes) e nessuna stampa. Sospensione tra 60 secondi..."
    sleep 60
    systemctl suspend
fi
