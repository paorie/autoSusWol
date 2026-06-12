#!/bin/bash
CONF="/etc/monitor-ports.conf"
ROUTER_IP="{{ROUTER_IP}}"
SSH_KEY="/root/.ssh/id_rsa_router"
SERVER_IP="{{SERVER_IP}}"
SERVER_MAC="{{SERVER_MAC}}"
SERVER_IFACE="{{SERVER_IFACE}}"
WOL_TIMEOUT={{WOL_TIMEOUT}}

# ============================================================
# SECTION 1 — Local NFT Rules on the Server
# ============================================================

PORT_LIST=$(grep -v 'wol-only' "$CONF" | sed 's/#.*//' | grep -Eo '[0-9]+' | tr '\n' ',' | sed 's/,$//')

if nft list table inet traffic_monitor >/dev/null 2>&1; then
  nft flush chain inet traffic_monitor monitor_input
  nft flush chain inet traffic_monitor monitor_forward
else
  nft add table inet traffic_monitor
  nft add chain inet traffic_monitor monitor_input \
    '{ type filter hook input priority -10 ; }'
  nft add chain inet traffic_monitor monitor_forward \
    '{ type filter hook forward priority -10 ; }'
fi

for proto in tcp udp; do
  nft add rule inet traffic_monitor monitor_input \
    "$proto dport { $PORT_LIST } counter"
  nft add rule inet traffic_monitor monitor_forward \
    "$proto dport { $PORT_LIST } counter"
done

# ============================================================
# SECTION 2 — UCI Firewall Rules on the Router
# ============================================================

UCI_CMDS="
while uci -q delete firewall.\$(uci show firewall | grep 'WOL_' | head -1 | cut -d. -f2 | cut -d= -f1) 2>/dev/null; do :; done
"

while IFS= read -r line; do
  [[ "$line" =~ ^[[:space:]]*$ ]] && continue
  [[ "$line" =~ ^[[:space:]]*# ]] && continue

  PORT=$(echo "$line" | grep -Eo '^[[:space:]]*[0-9]+' | tr -d ' ')
  COMMENT=$(echo "$line" | sed 's/.*#[[:space:]]*//' | sed 's/[[:space:]]*!wol-only.*//')

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
done <"$CONF"

UCI_CMDS+="
uci commit firewall
fw4 reload
"

# ============================================================
# SECTION 3 — WOL Script on the Router
# ============================================================

WOL_TRIGGER_SCRIPT=$(cat <<SCRIPT
#!/bin/sh
SERVER_IP="${SERVER_IP}"
SERVER_MAC="${SERVER_MAC}"
SERVER_IFACE="${SERVER_IFACE}"
WAIT_TIMEOUT=${WOL_TIMEOUT}
LOCKFILE="/tmp/wol-trigger.lock"

if [ -f "\$LOCKFILE" ]; then
    exit 0
fi

if ping -c1 -W1 "\$SERVER_IP" >/dev/null 2>&1; then
    exit 0
fi

touch "\$LOCKFILE"
logger -t wol-trigger "Server unreachable, sending magic packet to \$SERVER_MAC"
etherwake -i "\$SERVER_IFACE" "\$SERVER_MAC"

i=0
while [ \$i -lt \$WAIT_TIMEOUT ]; do
    if ping -c1 -W1 "\$SERVER_IP" >/dev/null 2>&1; then
        logger -t wol-trigger "Server reachable after \${i}s"
        rm -f "\$LOCKFILE"
        exit 0
    fi
    sleep 1
    i=\$((i+1))
done

logger -t wol-trigger "Timeout: server not responding after \${WAIT_TIMEOUT}s"
rm -f "\$LOCKFILE"
exit 1
SCRIPT
)

WOL_MONITOR_SCRIPT=$(cat <<'SCRIPT'
#!/bin/sh
logread -f | grep -i "WOL_" | while read -r line; do
    /usr/local/bin/wol-trigger.sh &
done
SCRIPT
)

WOL_INIT_SCRIPT=$(cat <<'SCRIPT'
#!/bin/sh /etc/rc.common
START=99
STOP=10

PIDFILE="/var/run/wol-monitor.pid"

boot() {
    start
}

start() {
    /usr/local/bin/wol-monitor.sh &
    echo $! > "$PIDFILE"
}

stop() {
    if [ -f "$PIDFILE" ]; then
        kill $(cat "$PIDFILE") 2>/dev/null
        rm -f "$PIDFILE"
    fi
    kill $(ps | grep "wol-monitor" | grep -v grep | awk '{print $1}') 2>/dev/null
    kill $(ps | grep "logread -f" | grep -v grep | awk '{print $1}') 2>/dev/null
}
SCRIPT
)

ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" "mkdir -p /usr/local/bin"

printf '%s\n' "${WOL_TRIGGER_SCRIPT}" | ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" \
  "cat > /usr/local/bin/wol-trigger.sh && chmod +x /usr/local/bin/wol-trigger.sh"

printf '%s\n' "${WOL_MONITOR_SCRIPT}" | ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" \
  "cat > /usr/local/bin/wol-monitor.sh && chmod +x /usr/local/bin/wol-monitor.sh"

printf '%s\n' "${WOL_INIT_SCRIPT}" | ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" \
  "cat > /etc/init.d/wol-monitor && chmod +x /etc/init.d/wol-monitor \
   && /etc/init.d/wol-monitor enable && /etc/init.d/wol-monitor restart"

# ============================================================
# SECTION 4 — UCI Firewall Rules on the Router
# ============================================================
ssh -i "$SSH_KEY" -T -q "root@$ROUTER_IP" "$UCI_CMDS"
