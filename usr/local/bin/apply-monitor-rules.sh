#!/bin/bash
CONF="/etc/monitor-ports.conf"
ROUTER_IP="192.168.20.1"
SSH_KEY="/root/.ssh/id_rsa_router"
SERVER_IP="192.168.20.108"
SERVER_MAC="d0:27:88:c5:13:07"
SERVER_IFACE="br-server"
WOL_TIMEOUT=15  # secondi attesa risveglio (suspend ~8s)

# ============================================================
# SEZIONE 1 — Regole nft locali sul server
# ============================================================

PORT_LIST_NFT=$(grep -v 'wol-only' "$CONF" | sed 's/#.*//' | grep -Eo '[0-9]+' | tr '\n' ',' | sed 's/,$//')
PORT_LIST=$(sed 's/#.*//' "$CONF" | grep -Eo '[0-9]+' | tr '\n' ',' | sed 's/,$//')

if nft list table inet traffic_monitor >/dev/null 2>&1; then
    nft flush chain inet traffic_monitor monitor_input
    nft flush chain inet traffic_monitor monitor_forward
    nft reset counter inet traffic_monitor total_traffic
else
    nft add table inet traffic_monitor
    nft add chain inet traffic_monitor monitor_input \
        '{ type filter hook input priority -10 ; }'
    nft add chain inet traffic_monitor monitor_forward \
        '{ type filter hook forward priority -10 ; }'
    nft add counter inet traffic_monitor total_traffic
fi

for proto in tcp udp; do
    nft add rule inet traffic_monitor monitor_input \
        "$proto dport { $PORT_LIST_NFT } counter"
    nft add rule inet traffic_monitor monitor_forward \
        "$proto dport { $PORT_LIST_NFT } counter"
done
nft add rule inet traffic_monitor monitor_input counter name total_traffic accept
# ============================================================
# SEZIONE 2 — Regole UCI firewall sul router
# ============================================================

UCI_CMDS="
# Rimuovi regole WOL esistenti
while uci -q delete firewall.\$(uci show firewall | grep 'WOL_' | head -1 | cut -d. -f2 | cut -d= -f1) 2>/dev/null; do :; done
"

while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue

    PORT=$(echo "$line" | grep -Eo '^[[:space:]]*[0-9]+' | tr -d ' ')
    COMMENT=$(echo "$line" | sed 's/.*#[[:space:]]*//')

    if [ "$COMMENT" = "$line" ] || [ -z "$COMMENT" ]; then
        NAME="WOL_${PORT}"
    else
        NAME="WOL_$(echo "$COMMENT" | tr ' ' '_' | tr -cd '[:alnum:]_')"
    fi

    UCI_CMDS+="
uci add firewall rule
uci set firewall.@rule[-1].name='${NAME}'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest='server'
uci set firewall.@rule[-1].dest_ip='${SERVER_IP}'
uci set firewall.@rule[-1].dest_port='${PORT}'
uci set firewall.@rule[-1].proto='tcp udp'
uci set firewall.@rule[-1].target='ACCEPT'
uci set firewall.@rule[-1].log='1'
uci set firewall.@rule[-1].log_limit='10/minute'
uci set firewall.@rule[-1].enabled='1'
"
done < "$CONF"

UCI_CMDS+="
uci commit firewall
fw4 reload
"

# ============================================================
# SEZIONE 3 — Script WOL sul router
# I valori delle variabili vengono espansi qui (lato server)
# e hardcodati negli script sul router.
# Usiamo printf+pipe per evitare problemi di quoting SSH.
# ============================================================

# --- wol-trigger.sh ---
WOL_TRIGGER_SCRIPT=$(cat << SCRIPT
#!/bin/sh
SERVER_IP="${SERVER_IP}"
SERVER_MAC="${SERVER_MAC}"
SERVER_IFACE="${SERVER_IFACE}"
WAIT_TIMEOUT=${WOL_TIMEOUT}
LOCKFILE="/tmp/wol-trigger.lock"

# Evita esecuzioni multiple simultanee
if [ -f "\$LOCKFILE" ]; then
    exit 0
fi

# Server gia' sveglio — non fare nulla
if ping -c1 -W1 "\$SERVER_IP" >/dev/null 2>&1; then
    exit 0
fi

touch "\$LOCKFILE"
logger -t wol-trigger "Server non raggiungibile, invio magic packet a \$SERVER_MAC"
etherwake -i "\$SERVER_IFACE" "\$SERVER_MAC"

i=0
while [ \$i -lt \$WAIT_TIMEOUT ]; do
    if ping -c1 -W1 "\$SERVER_IP" >/dev/null 2>&1; then
        logger -t wol-trigger "Server raggiungibile dopo \${i}s"
        rm -f "\$LOCKFILE"
        exit 0
    fi
    sleep 1
    i=\$((i+1))
done

logger -t wol-trigger "Timeout: server non risponde dopo \${WAIT_TIMEOUT}s"
rm -f "\$LOCKFILE"
exit 1
SCRIPT
)

# --- wol-monitor.sh ---
WOL_MONITOR_SCRIPT=$(cat << 'SCRIPT'
#!/bin/sh
# Monitora i log fw4 per prefissi WOL_ e sveglia il server
logread -f | grep -i "WOL_" | while read -r line; do
    /usr/local/bin/wol-trigger.sh &
done
SCRIPT
)

# --- init.d/wol-monitor ---
WOL_INIT_SCRIPT=$(cat << 'SCRIPT'
#!/bin/sh /etc/rc.common
START=99
STOP=10

PIDFILE="/var/run/wol-monitor.pid"

start() {
    stop 2>/dev/null
    sleep 1
    /usr/local/bin/wol-monitor.sh &
    echo $! > "$PIDFILE"
    return 0
}

stop() {
    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE")
        kill $PID 2>/dev/null
        rm -f "$PIDFILE"
    fi
    kill $(ps | grep "wol-monitor" | grep -v grep | awk "{print \$1}") 2>/dev/null
    kill $(ps | grep "logread -f" | grep -v grep | awk "{print \$1}") 2>/dev/null
    return 0
}
SCRIPT
)

# Copia gli script sul router via pipe — evita problemi di quoting
ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" "mkdir -p /usr/local/bin"
printf '%s\n' "${WOL_TRIGGER_SCRIPT}" | ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" \
    "cat > /usr/local/bin/wol-trigger.sh && chmod +x /usr/local/bin/wol-trigger.sh"

printf '%s\n' "${WOL_MONITOR_SCRIPT}" | ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" \
    "cat > /usr/local/bin/wol-monitor.sh && chmod +x /usr/local/bin/wol-monitor.sh"

printf '%s\n' "${WOL_INIT_SCRIPT}" | ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" \
    "cat > /etc/init.d/wol-monitor && chmod +x /etc/init.d/wol-monitor \
     && /etc/init.d/wol-monitor enable && /etc/init.d/wol-monitor restart"

# ============================================================
# SEZIONE 4 — Regole UCI firewall sul router
# ============================================================
ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" "$UCI_CMDS"
