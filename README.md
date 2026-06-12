# autoSusWol

Automatic server suspension and Wake-on-LAN system for home servers managed by an OpenWrt router.

## Overview

autoSusWol automatically suspends a home server when it's not in use and wakes it up on demand when a client tries to access its services. The system is split between the server and the OpenWrt router, which coordinate via SSH.

### How it works

1. A timer runs `check-traffic.sh` on the server every 5 minutes
2. The script checks for active connections to monitored services
3. If no activity is detected (and no printer/TV is in use), the server suspends after a 60-second grace period
4. The router monitors firewall logs for connection attempts to the server ports
5. When a connection attempt is detected, the router sends a WOL magic packet
6. The server wakes up and becomes available within ~10 seconds

## Architecture

```
+-------------------+         +------------------------+
|   CLIENT (LAN)    |         |   OPENWRT ROUTER       |
|   192.168.8.x     |-------->|   192.168.20.1         |
+-------------------+         |                        |
                              |  wol-monitor.sh         |
                              |  watches fw4 logs       |
                              |  sends WOL packet       |
                              +------------+-----------+
                                           | br-server (192.168.20.x)
                              +------------v-----------+
                              |   HOME SERVER           |
                              |   192.168.20.x          |
                              |                        |
                              |  check-traffic.sh       |
                              |  apply-monitor-rules    |
                              |  Docker containers:     |
                              |  - tvheadend            |
                              |  - portainer            |
                              |  - klipper              |
                              +------------------------+
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
- `nftables`, `curl`, `ss` (iproute2), `ethtool`
- `smbstatus` (samba-common, for Samba activity detection)
- WOL enabled in BIOS
- SSH access to the router

### Router
- OpenWrt 25.x with firewall4 (fw4)
- `etherwake` (`apk add etherwake`)
- Dedicated bridge interface for the server (`br-server`)

## Files

### Server side (`/usr/local/bin/`)

| File | Description |
|---|---|
| `apply-monitor-rules.sh` | Main config script — sets up nft rules on the server and deploys firewall rules + WOL scripts to the router via SSH |
| `check-traffic.sh` | Checks for active connections and suspends the server if idle |

### Server side (`/etc/`)

| File | Description |
|---|---|
| `monitor-ports.conf` | List of ports to monitor. Use `!wol-only` to include a port in the WOL trigger but exclude it from local connection checks |
| `systemd/system/apply-monitor-rules.service` | Runs `apply-monitor-rules.sh` at boot |
| `systemd/system/check-traffic.service` | Oneshot service triggered by the timer |
| `systemd/system/check-traffic.timer` | Runs `check-traffic.sh` every 5 minutes |
| `systemd/network/10-wol-eth1.link` | Template — installed as `10-wol-<iface>.link` with the actual NIC name |

### Server side (`/usr/lib/systemd/system-sleep/`)

| File | Description |
|---|---|
| `tbsecp3-reset.sh` | Stops tvheadend and unloads TBS PCIe DVB tuner drivers before suspend; reloads them and restarts tvheadend after resume. Only needed with TBS PCIe DVB tuner cards. |

### Router side (deployed automatically by `apply-monitor-rules.sh`)

| File | Description |
|---|---|
| `/usr/local/bin/wol-trigger.sh` | Sends WOL magic packet and waits for server to respond |
| `/usr/local/bin/wol-monitor.sh` | Monitors fw4 logs and calls `wol-trigger.sh` on demand |
| `/etc/init.d/wol-monitor` | Init script to start `wol-monitor.sh` at router boot |

## Configuration

The repository files use `{{PLACEHOLDER}}` syntax for all machine-specific values. The `install.sh` script detects and substitutes them automatically — **you should not edit the files manually before running install.sh**.

### Placeholders reference

| Placeholder | Description | Auto-detected |
|---|---|---|
| `{{NIC_IFACE}}` | Server NIC interface name (e.g. `eth1`, `enp3s0`) | yes |
| `{{NIC_MAC}}` | Server NIC MAC address | yes |
| `{{SERVER_IP}}` | Server IP on the server VLAN | yes |
| `{{ROUTER_IP}}` | Router IP on the server VLAN | yes (from default gateway) |
| `{{SERVER_IFACE}}` | Router bridge interface name (e.g. `br-server`) | asked (default: br-server) |
| `{{WOL_TIMEOUT}}` | Max seconds to wait for server after WOL | asked (default: 15) |
| `{{TVH_USER}}` | tvheadend admin username | asked (optional) |
| `{{TVH_PASSWORD}}` | tvheadend admin password | asked (optional) |
| `{{TBS_PCI_1}}` | PCI address of first TBS DVB card | yes via lspci (optional) |
| `{{TBS_PCI_2}}` | PCI address of second TBS DVB card | yes via lspci (optional) |

### `monitor-ports.conf`

```
# Format: PORT   # service_name [!wol-only]
#
# !wol-only: port is monitored by the router for WOL trigger
#            but excluded from local active-connection checks.
#            Use for services that generate background traffic
#            (e.g. tvheadend EPG sync, Samba keepalives).
#
#22   # ssh          -- disabled: avoid keeping server awake during admin sessions
80    # http
445   # samba         !wol-only  -- Samba activity checked via smbstatus instead
7125  # klipper
9000  # portainer
9090  # cockpit
9981  # tvheadend http  !wol-only
9982  # tvheadend https !wol-only
```

## Installation

### 1. Configure the router

Create a dedicated bridge interface for the server VLAN and connect the physical port:

```bash
# Remove the server port from the main LAN bridge (adjust lan2 to your port)
uci del_list network.@device[0].ports='lan2'

# Create the server bridge and interface
uci add network device
uci set network.@device[-1].type='bridge'
uci set network.@device[-1].name='br-server'
uci set network.@device[-1].ports='lan2'
uci set network.@device[-1].bridge_empty='1'

uci set network.SERVER=interface
uci set network.SERVER.proto='static'
uci set network.SERVER.device='br-server'
uci set network.SERVER.ipaddr='192.168.20.1'
uci set network.SERVER.netmask='255.255.255.0'

uci set dhcp.SERVER=dhcp
uci set dhcp.SERVER.interface='SERVER'
uci set dhcp.SERVER.start='100'
uci set dhcp.SERVER.limit='10'
uci set dhcp.SERVER.leasetime='12h'

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

uci commit network
uci commit dhcp
uci commit firewall
/etc/init.d/network restart
fw4 reload
```

### 2. Install etherwake on the router

```bash
apk add etherwake
```

### 3. Run the install script on the server

```bash
git clone https://github.com/paorie/autoSusWol.git
cd autoSusWol
sudo ./install.sh
```

The script will:
- Auto-detect NIC interface, MAC address, server IP and default gateway
- Ask for confirmation and the few values it cannot detect (router bridge name, tvheadend credentials, TBS card presence)
- Substitute all `{{PLACEHOLDER}}` values in the files before copying them
- Install the `.link` file with the correct NIC name (e.g. `10-wol-enp3s0.link`)
- Generate an SSH key and copy it to the router
- Enable WOL on the NIC via ethtool
- Enable and start systemd services
- Run `apply-monitor-rules.sh` to deploy WOL scripts and firewall rules to the router

### 4. Edit `monitor-ports.conf` if needed

After installation, edit `/etc/monitor-ports.conf` to add or remove monitored ports, then re-run:

```bash
sudo /usr/local/bin/apply-monitor-rules.sh
```

This re-deploys the firewall rules and WOL scripts to the router without reinstalling everything.

## Suspension logic

`check-traffic.sh` runs every 5 minutes and suspends the server only when ALL of the following are true:

1. **3D printer is not printing** -- checked via Klipper Moonraker API (`/printer/objects/query?print_stats`)
2. **No TV streaming active** -- checked via tvheadend API (`streaming: 1` in `/api/status/connections`)
3. **No Samba files open** -- checked via `smbstatus --locked` (ignores background keepalive connections from SMB clients like KDE Dolphin/KIO)
4. **No active TCP connections** on other monitored ports (80, 7125, 9000, 9090)

When all conditions are met, the script waits 60 seconds before suspending (grace period for pending operations).

### Why smbstatus instead of ss for Samba

SMB clients (including KDE Dolphin/KIO) maintain persistent TCP keepalive connections to Samba shares even when no files are in use. Using `ss` to detect port 445 activity would prevent the server from ever suspending. `smbstatus --locked` only reports files that are actually open, making it a reliable indicator of real Samba usage.

### Why !wol-only for tvheadend and Samba

These services generate continuous background traffic (EPG sync, SMB keepalives) that would prevent suspension even when not actively in use. Marking them `!wol-only` excludes them from local traffic monitoring while keeping them in the router WOL trigger rules -- so the server still wakes up when a client actually tries to connect.

## WOL trigger logic

`wol-monitor.sh` on the router monitors fw4 firewall logs continuously. When a `WOL_` prefixed log entry appears (meaning a client tried to connect to the server), `wol-trigger.sh` is called which:

1. Checks if the server is already reachable (ping) -- exits if yes
2. Uses a lockfile to prevent multiple simultaneous wake attempts
3. Sends a WOL magic packet via `etherwake`
4. Polls the server every second until it responds (max `WOL_TIMEOUT` seconds)
5. Logs all actions via `logger`

## DVB tuner reset after suspend (optional)

If using TBS PCIe DVB tuner cards, `tbsecp3-reset.sh` is installed by `install.sh` to handle the driver lifecycle around suspend/resume.

The script is called automatically by systemd-sleep at `/usr/lib/systemd/system-sleep/tbsecp3-reset.sh`.

**Pre-suspend**: stops the tvheadend container, removes the TBS PCIe devices from the PCI bus, then unloads the driver modules (`tbsecp3`, `gx1133`, `tas2101`) to prevent i2c timeout errors that can cause the system to freeze during suspend.

**Post-resume**: rescans the PCI bus to re-detect the cards, reloads the driver modules in the correct dependency order, then restarts the tvheadend container.

The PCI addresses are specific to the hardware -- `install.sh` detects them automatically via `lspci`, or asks for them if not found.

## Troubleshooting

**Server doesn't suspend**
- Run `sudo bash -x /usr/local/bin/check-traffic.sh` to see which check is blocking
- Check Samba file activity: `sudo smbstatus --locked`
- Check tvheadend connections: `curl -s "http://user:pass@localhost:9981/api/status/connections"`
- Check other active connections: `ss -tn state established`

**Server doesn't wake up**
- Check router logs: `logread | grep -E "WOL_|wol-trigger"`
- Verify wol-monitor is running on the router: `ps | grep wol`
- Start wol-monitor manually: `/etc/init.d/wol-monitor start`
- Test WOL manually: `etherwake -i br-server <MAC_ADDRESS>`
- Verify WOL is enabled on the server NIC: `ethtool <iface> | grep Wake`

**System freezes during suspend (TBS cards)**
- Check for i2c timeout errors: `journalctl -b -1 | grep "i2c xfer timeout"`
- Verify tbsecp3-reset.sh is executable: `ls -la /usr/lib/systemd/system-sleep/tbsecp3-reset.sh`
- Verify PCI addresses match your hardware: `lspci | grep -i tbs`

**apply-monitor-rules.sh fails**
- Check SSH connectivity: `sudo ssh -i /root/.ssh/id_rsa_router root@<ROUTER_IP> "echo OK"`
- Check router reachability: `ping <ROUTER_IP>`
- Run with debug: `sudo bash -x /usr/local/bin/apply-monitor-rules.sh`

**install.sh -- SSH key copy fails**
- Copy manually: `ssh-copy-id -i /root/.ssh/id_rsa_router.pub root@<ROUTER_IP>`
- Then re-run deploy: `sudo /usr/local/bin/apply-monitor-rules.sh`
