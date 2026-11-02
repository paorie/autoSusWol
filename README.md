# autoSusWol

Automatic server suspension and Wake-on-LAN system for home servers managed by an OpenWrt router.

## Overview

autoSusWol automatically suspends a home server when it's not in use and wakes it up on demand when a client tries to access its services. The system is split between the server and the OpenWrt router, which coordinate via SSH.

### How it works

1. A timer runs `check-traffic.sh` on the server every 5 minutes
2. The script checks for active connections to monitored services
3. If no activity is detected (no print job, TV streaming, open Samba files, Jellyfin playback or active connections), the server suspends after a 60-second grace period
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
                              |  Containers:            |
                              |  - tvheadend            |
                              |  - jellyfin             |
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
- `jq` (only if the optional Jellyfin check is enabled)
- WOL enabled in BIOS
- SSH access to the router

### Router
- OpenWrt 25.x with firewall4 (fw4)
- `etherwake` (`apk add etherwake`)
- Dedicated bridge interface for the server (`br-server`) and a firewall zone named `server` (see Installation, step 1)

## Files

### Server side (`/usr/local/bin/`)

| File | Description |
|---|---|
| `apply-monitor-rules.sh` | Main config script — deploys firewall rules + WOL scripts to the router via SSH. It also creates nft packet counters on the server, which `check-traffic.sh` no longer reads (it uses established connections instead) |
| `check-traffic.sh` | Checks printer, tvheadend, Samba, Jellyfin and active connections, and suspends the server if idle |

### Server side (`/etc/`)

| File | Description |
|---|---|
| `monitor-ports.conf` | List of ports to monitor. Every port wakes the server through the router; ports **not** marked `!wol-only` also keep it awake while they have established connections |
| `systemd/system/apply-monitor-rules.service` | Runs `apply-monitor-rules.sh` at boot |
| `systemd/system/check-traffic.service` | Oneshot service triggered by the timer |
| `systemd/system/check-traffic.timer` | Runs `check-traffic.sh` every 5 minutes |
| `systemd/network/10-wol-eth1.link` | Template — installed as `10-wol-<iface>.link` with the actual NIC name |

### Server side (`/usr/lib/systemd/system-sleep/`)

| File | Description |
|---|---|
| `tbsecp3-reset.sh` | Stops tvheadend and unloads TBS PCIe DVB tuner drivers before suspend; reloads them and restarts tvheadend after resume. Only needed with TBS PCIe DVB tuner cards. |

### NixOS (`flake.nix`, `nix/`)

| File | Description |
|---|---|
| `flake.nix` | Exposes `nixosModules.default` (alias `nixosModules.autoSusWol`) |
| `nix/module.nix` | The `services.autoSusWol` module: wraps the scripts above, generates `/etc/monitor-ports.conf`, the systemd units and the sleep hook. See [NixOS](#nixos) |

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
| `{{SERVER_MAC}}` | Server MAC used by the router for the magic packet (same value as `{{NIC_MAC}}`) | yes |
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
8096  # jellyfin        !wol-only  -- playback checked via the Jellyfin API instead
```

The same list drives both sides: `apply-monitor-rules.sh` turns every line into a `WOL_<name>` rule on the router, and `check-traffic.sh` treats every port **without** `!wol-only` as "in use" while it has established connections. After editing, re-run `apply-monitor-rules.sh` (NixOS: change `services.autoSusWol.ports` and rebuild).

Secrets are not part of this file: `JELLYFIN_API_KEY` (and optionally `JELLYFIN_URL`) are read from the environment of `check-traffic.service`, see [Jellyfin](#jellyfin).

## Installation

### 1. Prepare the server network on the router (one-time, not automated)

Neither `install.sh` nor `apply-monitor-rules.sh` touches the router's network configuration. They only deploy the `WOL_*` firewall rules and the WOL scripts, and those rules assume the server lives in its own network and firewall zone:

- the server sits behind a dedicated bridge (`br-server`, subnet `192.168.20.0/24`) instead of the main LAN, so every connection from a client to the server is *routed* by the router. This is what lets fw4 log the attempt and trigger the wake-up;
- the firewall zone must be named `server` and the clients' zone `lan`: the generated rules are hard-coded as `src='lan'` → `dest='server'`.

If your router already has such a network, skip this step. You can check with `uci show network.SERVER` and `ip a show br-server`. Otherwise run the commands below once, adjusting `lan2` to the port the server is plugged into. Do not run them twice: `uci add` would create duplicate entries.

<details>
<summary>Commands to create the server network</summary>

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

</details>

### 2. Install etherwake on the router (not automated either)

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
3. **No Samba files open** -- checked via `smbstatus -L` (ignores background keepalive connections from SMB clients like KDE Dolphin/KIO)
4. **No Jellyfin playback** (optional) -- checked via the Jellyfin API (`GET /Sessions`: a session counts only if it has a `NowPlayingItem` and is not paused). Skipped when `JELLYFIN_API_KEY` is empty
5. **No active TCP connections** on the monitored ports listed in `/etc/monitor-ports.conf` (ports marked `!wol-only` are excluded)

When all conditions are met, the script waits 60 seconds before suspending (grace period for pending operations).

### Jellyfin

Create an API key in Jellyfin (Dashboard → Advanced → API Keys) and pass it to the service as `JELLYFIN_API_KEY` (optionally `JELLYFIN_URL`, default `http://localhost:8096`). On a classic install use a systemd drop-in (`systemctl edit check-traffic.service`):

```ini
[Service]
Environment=JELLYFIN_API_KEY=your-key
```

Mark port 8096 as `!wol-only` in `monitor-ports.conf`: the web UI keeps WebSocket connections open even when nothing is playing, so the API check is the reliable one.

### Why smbstatus instead of ss for Samba

SMB clients (including KDE Dolphin/KIO) maintain persistent TCP keepalive connections to Samba shares even when no files are in use. Using `ss` to detect port 445 activity would prevent the server from ever suspending. `smbstatus -L` only reports files that are actually open, making it a reliable indicator of real Samba usage.

### Why !wol-only for tvheadend and Samba

These services generate continuous background traffic (EPG sync, SMB keepalives) that would prevent suspension even when not actively in use. Marking them `!wol-only` excludes them from local traffic monitoring while keeping them in the router WOL trigger rules -- so the server still wakes up when a client actually tries to connect.

## NixOS

The repository is also a flake exposing a NixOS module, so no `install.sh` is needed. The module reuses the very same scripts: `{{PLACEHOLDER}}` values are filled at build time from the module options, and secrets are read at runtime from an `environmentFile` (they never enter the Nix store).

```nix
# flake.nix of the server
inputs.autosuswol.url = "github:paorie/autoSusWol";

# in the modules list
autosuswol.nixosModules.default
{
  services.autoSusWol = {
    enable = true;
    nic = "eth1";
    serverIp = "192.168.20.100";
    routerIp = "192.168.20.1";
    environmentFile = "/run/secrets/autosuswol.env"; # TVH_USER, TVH_PASSWORD, JELLYFIN_API_KEY (all optional)
    ports = [
      { port = 80;   name = "http"; }
      { port = 445;  name = "samba";    wolOnly = true; }
      { port = 8096; name = "jellyfin"; wolOnly = true; }
    ];
    # TBS PCIe tuners, tvheadend managed as a systemd unit (e.g. a Quadlet container)
    tbs = {
      enable = true;
      pciAddresses = [ "0000:01:00.0" "0000:02:00.0" ];
      tvheadendUnit = "tvheadend.service";
    };
  };
}
```

Other options: `routerSshKey` (private key used to configure the router, default `/root/.ssh/id_rsa_router`), `routerHostKey` (router host key for `known_hosts`), `mac`, `routerBridge`, `wolTimeout`, `manageWol`. The out-of-tree `tbsecp3` kernel module is not provided by this module.

What the module sets up:
- `/etc/monitor-ports.conf`, generated from `ports`
- `check-traffic.service` and `check-traffic.timer` (every 5 minutes)
- `apply-monitor-rules.service` at boot, and again whenever `ports` changes
- Wake-on-LAN on the NIC (`manageWol`)
- with `tbs.enable`, `tbsecp3-reset.service` bound to `sleep.target`, which replaces the system-sleep hook: it stops tvheadend and unloads the drivers when the system goes to sleep, and reverses that on resume

### Router prerequisites and SSH key

The router side is unchanged. Steps 1 and 2 of [Installation](#installation) (server network/zone and `etherwake`) are one-time prerequisites that no script performs, on any distro; the `WOL_*` firewall rules and the WOL scripts are deployed automatically by `apply-monitor-rules.sh`.

`install.sh` is not used on NixOS, so nothing generates the SSH key the server uses to reach the router. Create it once and add the public key to the router as a plain line (the script runs `uci`, `cat >` and init scripts, so it cannot be a restricted `command=` key):

```bash
ssh-keygen -t ed25519 -N "" -C "autosuswol" -f ./id_router
ssh root@<ROUTER_IP> 'cat >> /etc/dropbear/authorized_keys' < id_router.pub
```

Keep the private key as a secret, for example with sops-nix (store it as a multi-line `|` YAML block so the trailing newline is kept), and point the module at it:

```nix
sops.secrets."autosuswol/router_ssh_key" = { };
sops.secrets."autosuswol/jellyfin_api_key" = { };
sops.templates."autosuswol.env".content = ''
  JELLYFIN_API_KEY=${config.sops.placeholder."autosuswol/jellyfin_api_key"}
'';

services.autoSusWol.routerSshKey = config.sops.secrets."autosuswol/router_ssh_key".path;
services.autoSusWol.environmentFile = config.sops.templates."autosuswol.env".path;
```

Finally accept the router's host key once with `sudo ssh -i <key> root@<ROUTER_IP>`, or set `routerHostKey`.

## WOL trigger logic

`wol-monitor.sh` on the router monitors fw4 firewall logs continuously. When a `WOL_` prefixed log entry appears (meaning a client tried to connect to the server), `wol-trigger.sh` is called which:

1. Checks if the server is already reachable (ping) -- exits if yes
2. Uses a lockfile to prevent multiple simultaneous wake attempts
3. Sends a WOL magic packet via `etherwake`
4. Polls the server every second until it responds (max `WOL_TIMEOUT` seconds)
5. Logs all actions via `logger`

## DVB tuner reset after suspend (optional)

If using TBS PCIe DVB tuner cards, `tbsecp3-reset.sh` is installed by `install.sh` to handle the driver lifecycle around suspend/resume.

The script is called automatically by systemd-sleep at `/usr/lib/systemd/system-sleep/tbsecp3-reset.sh`. On NixOS the module runs the same script from a systemd unit bound to `sleep.target` instead.

By default tvheadend is a Docker container. If it is a systemd unit instead (e.g. a Podman Quadlet), set `TVH_UNIT=tvheadend.service` in the script's environment and it is stopped/started with `systemctl` (a plain `podman stop` would be undone by the unit's restart policy).

**Pre-suspend**: stops the tvheadend container, removes the TBS PCIe devices from the PCI bus, then unloads the driver modules (`tbsecp3`, `gx1133`, `tas2101`) to prevent i2c timeout errors that can cause the system to freeze during suspend.

**Post-resume**: rescans the PCI bus to re-detect the cards, reloads the driver modules in the correct dependency order, then restarts the tvheadend container.

The PCI addresses are specific to the hardware -- `install.sh` detects them automatically via `lspci`, or asks for them if not found.

## Troubleshooting

**Server doesn't suspend**
- Every run logs why it did or did not suspend: `journalctl -u check-traffic -n 20`
- Run `sudo bash -x /usr/local/bin/check-traffic.sh` to see which check is blocking (it suspends the server if nothing is blocking). On NixOS the script is in the Nix store: `systemctl cat check-traffic` shows its path
- Check Samba file activity: `sudo smbstatus --locked`
- Check Jellyfin sessions: `curl -s -H "X-Emby-Token: <API_KEY>" http://localhost:8096/Sessions | jq '.[] | {item: .NowPlayingItem.Name, paused: .PlayState.IsPaused}'`
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
- Check SSH connectivity: `sudo ssh -i /root/.ssh/id_rsa_router root@<ROUTER_IP> "echo OK"` (NixOS: use the path set in `routerSshKey`; `Host key verification failed` means the router host key was never accepted, see [Router prerequisites and SSH key](#router-prerequisites-and-ssh-key))
- NixOS: `systemctl status apply-monitor-rules` and `journalctl -u apply-monitor-rules`
- Check router reachability: `ping <ROUTER_IP>`
- Run with debug: `sudo bash -x /usr/local/bin/apply-monitor-rules.sh`

**install.sh -- SSH key copy fails**
- Copy manually: `ssh-copy-id -i /root/.ssh/id_rsa_router.pub root@<ROUTER_IP>`
- Then re-run deploy: `sudo /usr/local/bin/apply-monitor-rules.sh`
