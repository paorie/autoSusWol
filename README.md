# autoSusWol

Automatic server suspension and Wake-on-LAN system for home servers managed by an OpenWrt router.

## Overview

autoSusWol automatically suspends a home server when it's not in use and wakes it up on demand when a client tries to access its services. The system is split between the server and the OpenWrt router, which coordinate via SSH.

### How it works

1. A timer runs `check-traffic.sh` on the server every 5 minutes
2. The script checks for active connections to monitored services
3. If no activity is detected (and no printer/TV is in use), the server suspends after a 60-second grace period
4. The router monitors firewall logs for connection attempts to the server's ports
5. When a connection attempt is detected, the router sends a WOL magic packet
6. The server wakes up and becomes available within ~10 seconds

## Architecture

```
┌─────────────────┐         ┌──────────────────────┐
│   CLIENT (LAN)  │         │   OPENWRT ROUTER      │
│  192.168.8.x    │────────▶│   192.168.20.1        │
└─────────────────┘         │                       │
                            │  wol-monitor.sh        │
                            │  watches fw4 logs      │
                            │  sends WOL packet      │
                            └──────────┬────────────┘
                                       │ br-server (192.168.20.x)
                            ┌──────────▼────────────┐
                            │   HOME SERVER          │
                            │   192.168.20.108       │
                            │                       │
                            │  check-traffic.sh      │
                            │  apply-monitor-rules   │
                            │  Docker containers:    │
                            │  - tvheadend           │
                            │  - portainer           │
                            │  - klipper             │
                            └───────────────────────┘
```

## Network topology

| Network | Subnet | Purpose |
|---|---|---|
| LAN | 192.168.8.x | Main network (clients) |
| SERVER | 192.168.20.x | Dedicated server VLAN |
| IoT | 192.168.10.x | Isolated IoT devices |

The server VLAN is configured so that all traffic between LAN and server passes through the router — this is essential for the WOL trigger to work.

## Requirements

### Server
- Linux with systemd
- `nftables`
- `curl`
- `ss` (iproute2)
- `smbstatus` (samba-common package, for Samba activity detection)
- WOL enabled in BIOS and on the NIC (`ethtool -s ethX wol g`)
- SSH key pair for passwordless access to the router

### Router
- OpenWrt 25.x with firewall4 (fw4)
- `etherwake` (`apk add etherwake`)
- Dedicated bridge interface for the server (`br-server`)

## Files

### Server side (`/usr/local/bin/`)

| File | Description |
|---|---|
| `apply-monitor-rules.sh` | Main configuration script — sets up nft rules on the server and firewall rules + WOL scripts on the router |
| `check-traffic.sh` | Checks for active connections and suspends the server if idle |

### Server side (`/etc/`)

| File | Description |
|---|---|
| `monitor-ports.conf` | List of ports to monitor. Use `!wol-only` tag to include a port in WOL trigger but exclude it from local traffic monitoring |
| `systemd/system/apply-monitor-rules.service` | Runs `apply-monitor-rules.sh` at boot |
| `systemd/system/check-traffic.service` | Oneshot service triggered by the timer |
| `systemd/system/check-traffic.timer` | Runs `check-traffic.sh` every 5 minutes |
| `systemd/network/10-wol-eth1.link` | Enables WOL on the server NIC at boot |

### Server side (`/usr/lib/systemd/system-sleep/`)

| File | Description |
|---|---|
| `tbsecp3-reset.sh` | Stops tvheadend and unloads TBS PCIe DVB tuner drivers before suspend, reloads them and restarts tvheadend after resume. Only needed if using TBS PCIe DVB tuner cards. |

### Router side (deployed automatically by `apply-monitor-rules.sh`)

| File | Description |
|---|---|
| `/usr/local/bin/wol-trigger.sh` | Sends WOL magic packet and waits for server to respond |
| `/usr/local/bin/wol-monitor.sh` | Monitors fw4 logs and calls `wol-trigger.sh` on demand |
| `/etc/init.d/wol-monitor` | Init script to start `wol-monitor.sh` at router boot |

## Configuration

### `monitor-ports.conf`

```
# Elenco porte da monitorare
# Format: PORT   # service_name [!wol-only]
#
# !wol-only: port is monitored by the router for WOL trigger
#            but excluded from local active-connection checks.
#            Use for services that generate background traffic
#            (e.g. tvheadend EPG sync, Samba keepalives).
#
#22   # ssh          — disabled: avoid keeping server awake during admin sessions
80    # http
445   # samba         !wol-only  — Samba activity checked via smbstatus instead
7125  # klipper
9000  # portainer
9090  # cockpit
9981  # tvheadend http  !wol-only
9982  # tvheadend https !wol-only
```

### Key variables in `apply-monitor-rules.sh`

```bash
ROUTER_IP="192.168.20.1"       # Router IP on server VLAN
SERVER_IP="192.168.20.108"     # Server IP on server VLAN
SERVER_MAC="d0:27:88:c5:13:07" # Server NIC MAC address
SERVER_IFACE="br-server"       # Router bridge interface for server VLAN
WOL_TIMEOUT=15                 # Max seconds to wait for server after WOL
```

### Key variables in `check-traffic.sh`

```bash
TVH_USER="your_tvh_admin_user"
TVH_PASSWORD="your_tvh_admin_password"
```

## Installation

### 1. Configure the router

Create a dedicated bridge interface for the server VLAN:

```bash
uci set network.SERVER=interface
uci set network.SERVER.proto='static'
uci set network.SERVER.device='br-server'
uci set network.SERVER.ipaddr='192.168.20.1'
uci set network.SERVER.netmask='255.255.255.0'
uci commit network
/etc/init.d/network restart
```

Create the firewall zone and forwarding rules:

```bash
uci add firewall zone
uci set firewall.@zone[-1].name='server'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'
uci add_list firewall.@zone[-1].network='SERVER'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='server'
uci set firewall.@forwarding[-1].dest='wan'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='server'
uci set firewall.@forwarding[-1].dest='lan'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='lan'
uci set firewall.@forwarding[-1].dest='server'

uci commit firewall
fw4 reload
```

### 2. Set up SSH key on the server

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_rsa_router -N "" -C "server-wol-script"
ssh-copy-id -i /root/.ssh/id_rsa_router.pub root@192.168.20.1
ssh-keyscan -H 192.168.20.1 | sudo tee -a /root/.ssh/known_hosts
```

### 3. Install etherwake on the router

```bash
apk add etherwake
```

### 4. Enable WOL on the server NIC

```bash
# Enable immediately
sudo ethtool -s eth1 wol g

# Make persistent via systemd-networkd
sudo tee /etc/systemd/network/10-wol-eth1.link << 'EOF'
[Match]
MACAddress=d0:27:88:c5:13:07

[Link]
Name=eth1
WakeOnLan=magic
EOF
```
### 5. Deploy the scripts

```bash
# Clone the repo
git clone https://github.com/paorie/autoSusWol.git
cd autoSusWol

# Copy files to their destinations
sudo cp usr/local/bin/apply-monitor-rules.sh /usr/local/bin/
sudo cp usr/local/bin/check-traffic.sh /usr/local/bin/
sudo cp etc/monitor-ports.conf /etc/
sudo cp etc/systemd/system/apply-monitor-rules.service /etc/systemd/system/
sudo cp etc/systemd/system/check-traffic.service /etc/systemd/system/
sudo cp etc/systemd/system/check-traffic.timer /etc/systemd/system/

# Set permissions
sudo chmod +x /usr/local/bin/apply-monitor-rules.sh
sudo chmod +x /usr/local/bin/check-traffic.sh

# Edit configuration
sudo nano /etc/monitor-ports.conf
sudo nano /usr/local/bin/apply-monitor-rules.sh  # set ROUTER_IP, SERVER_IP, SERVER_MAC
sudo nano /usr/local/bin/check-traffic.sh        # set TVH_USER, TVH_PASSWORD

# Run apply-monitor-rules to deploy everything
sudo /usr/local/bin/apply-monitor-rules.sh

# Enable and start services
sudo systemctl daemon-reload
sudo systemctl enable apply-monitor-rules.service
sudo systemctl enable check-traffic.timer
sudo systemctl start check-traffic.timer
```

## Suspension logic

`check-traffic.sh` runs every 5 minutes and suspends the server only when ALL of the following are true:

1. **3D printer is not printing** — checked via Klipper Moonraker API
2. **No TV streaming active** — checked via tvheadend API (`streaming: 1` field)
3. **No active TCP connections** on monitored ports (excluding `!wol-only` ports)

When all conditions are met, the script waits 60 seconds before suspending (grace period for pending operations).

## WOL trigger logic

`wol-monitor.sh` on the router monitors fw4 firewall logs continuously. When a `WOL_` prefixed log entry appears (meaning a client tried to connect to the server), `wol-trigger.sh` is called which:

1. Checks if the server is already reachable (ping) — exits if yes
2. Uses a lockfile to prevent multiple simultaneous wake attempts
3. Sends a WOL magic packet via `etherwake`
4. Polls the server every second until it responds (max 15 seconds)
5. Logs all actions via `logger`

## DVB tuner reset after suspend

If using TBS PCIe DVB tuner cards, add the following sleep hook to reinitialize them after resume:

```bash
# /usr/lib/systemd/system-sleep/tbsecp3-reset.sh
#!/bin/bash

# Usa il nome del container invece dell'ID dinamico
CONTAINER_NAME=$(docker ps -a | grep -i tvheadend | awk '{print $NF}')

case $1 in
    pre)
        echo "tbsecp3-reset: pre-suspend - stopping tvheadend and unloading modules"
        docker stop -t 3 "$CONTAINER_NAME" 2>/dev/null
        # Forza reset PCIe prima di scaricare il modulo
        echo 1 > /sys/bus/pci/devices/0000:01:00.0/remove 2>/dev/null
        echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove 2>/dev/null
        sleep 1
        modprobe -r tbsecp3
        modprobe -r gx1133
        modprobe -r tas2101
        ;;
    post)
        echo "tbsecp3-reset: post-resume - reloading modules and starting tvheadend"
        sleep 2
        # Rescan PCIe bus per rilevare le schede
        echo 1 > /sys/bus/pci/rescan
        sleep 2
        modprobe tas2101
        modprobe gx1133
        modprobe tbsecp3
        sleep 5
        docker start "$CONTAINER_NAME" 2>/dev/null
        ;;
esac

## Troubleshooting

**Server doesn't suspend**
- Run `sudo bash -x /usr/local/bin/check-traffic.sh` to see which check is blocking
- Check active connections: `ss -tn state established`
- Check tvheadend connections: `curl -s "http://user:pass@localhost:9981/api/status/connections"`

**Server doesn't wake up**
- Check router logs: `logread | grep -E "WOL_|wol-trigger"`
- Verify wol-monitor is running: `ps | grep wol`
- Test WOL manually: `etherwake -i br-server MAC_ADDRESS`
- Verify WOL is enabled on server NIC: `ethtool eth1 | grep Wake`

**apply-monitor-rules.sh fails**
- Check SSH connectivity: `sudo ssh -i /root/.ssh/id_rsa_router root@192.168.20.1 "echo OK"`
- Check router reachability: `ping 192.168.20.1`
- Run with debug: `sudo bash -x /usr/local/bin/apply-monitor-rules.sh`
