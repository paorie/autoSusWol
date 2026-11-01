{ config, lib, pkgs, ... }:

# Modulo NixOS per autoSusWol.
#
# Gli script del repo restano gli stessi usati su Fedora: i placeholder
# {{...}} vengono sostituiti in fase di build al posto di install.sh.
# I segreti (TVH_USER, TVH_PASSWORD, JELLYFIN_API_KEY) NON finiscono nello
# store di Nix: arrivano a runtime da `environmentFile`.

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.autoSusWol;

  mac =
    if cfg.mac != null
    then cfg.mac
    else "$(cat /sys/class/net/${cfg.nic}/address)";

  pci = n:
    if builtins.length cfg.tbs.pciAddresses > n
    then builtins.elemAt cfg.tbs.pciAddresses n
    else "0000:00:00.0";

  placeholders = {
    ROUTER_IP = cfg.routerIp;
    SERVER_IP = cfg.serverIp;
    SERVER_MAC = mac;
    NIC_MAC = mac;
    NIC_IFACE = cfg.nic;
    SERVER_IFACE = cfg.routerBridge;
    WOL_TIMEOUT = toString cfg.wolTimeout;
    TBS_PCI_1 = pci 0;
    TBS_PCI_2 = pci 1;
    # Segreti: la shell li legge dall'ambiente (EnvironmentFile)
    TVH_USER = "\${TVH_USER:-}";
    TVH_PASSWORD = "\${TVH_PASSWORD:-}";
  };

  fill = lib.replaceStrings
    (map (k: "{{${k}}}") (lib.attrNames placeholders))
    (lib.attrValues placeholders);

  # bashOptions = [ ]: gli script usano `grep -c` (exit 1 se 0 match) e non
  # sono scritti per `set -e`/`pipefail`, che cambierebbero il comportamento.
  mkScript = { name, file, inputs, extra ? (s: s) }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = inputs;
      bashOptions = [ ];
      checkPhase = "${pkgs.bash}/bin/bash -n \"$target\"";
      text = extra (fill (builtins.readFile file));
    };

  checkTraffic = mkScript {
    name = "check-traffic";
    file = ../usr/local/bin/check-traffic.sh;
    inputs = with pkgs; [
      coreutils
      curl
      gnugrep
      gnused
      iproute2
      jq
      systemd
      config.services.samba.package # smbstatus
    ];
  };

  applyRules = mkScript {
    name = "apply-monitor-rules";
    file = ../usr/local/bin/apply-monitor-rules.sh;
    inputs = with pkgs; [ coreutils gnugrep gnused nftables openssh ];
    extra = lib.replaceStrings [ "/root/.ssh/id_rsa_router" ] [ cfg.routerSshKey ];
  };

  tbsReset = mkScript {
    name = "tbsecp3-reset";
    file = ../usr/lib/systemd/system-sleep/tbsecp3-reset.sh;
    inputs = with pkgs; [ coreutils gawk gnugrep kmod systemd ]
      ++ lib.optional (cfg.tbs.tvheadendUnit == null) pkgs.docker;
  };

  portsConf =
    "# Generato da NixOS (services.autoSusWol.ports), non modificare a mano\n"
    + lib.concatMapStrings
      (p: "${toString p.port} # ${p.name}${lib.optionalString p.wolOnly " !wol-only"}\n")
      cfg.ports;
in
{
  options.services.autoSusWol = {
    enable = mkEnableOption "autoSusWol (sospensione automatica + Wake-on-LAN via router OpenWrt)";

    nic = mkOption {
      type = types.str;
      example = "eth1";
      description = "Interfaccia di rete del server collegata alla VLAN server.";
    };

    serverIp = mkOption {
      type = types.str;
      example = "192.168.20.100";
      description = "IP del server sulla VLAN server.";
    };

    routerIp = mkOption {
      type = types.str;
      example = "192.168.20.1";
      description = "IP del router OpenWrt sulla VLAN server.";
    };

    routerBridge = mkOption {
      type = types.str;
      default = "br-server";
      description = "Nome del bridge del router a cui è collegato il server (usato da etherwake).";
    };

    mac = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "d0:27:88:c5:13:07";
      description = "MAC del server. Se null viene letto a runtime da /sys/class/net/<nic>/address.";
    };

    wolTimeout = mkOption {
      type = types.ints.positive;
      default = 15;
      description = "Secondi massimi di attesa del server dopo l'invio del magic packet.";
    };

    manageWol = mkOption {
      type = types.bool;
      default = true;
      description = "Abilita il Wake-on-LAN sulla NIC (networking.interfaces.<nic>.wakeOnLan).";
    };

    ports = mkOption {
      default = [ ];
      description = ''
        Porte monitorate (contenuto di /etc/monitor-ports.conf). Con
        `wolOnly = true` la porta fa solo svegliare il server dal router e non
        impedisce la sospensione. Usalo per servizi con traffico di fondo
        (tvheadend, Samba, Jellyfin: per questi esistono controlli dedicati).
      '';
      example = [
        { port = 80; name = "http"; }
        { port = 8096; name = "jellyfin"; wolOnly = true; }
      ];
      type = types.listOf (types.submodule {
        options = {
          port = mkOption { type = types.port; };
          name = mkOption { type = types.str; };
          wolOnly = mkOption { type = types.bool; default = false; };
        };
      });
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/autosuswol.env";
      description = ''
        File con i segreti, formato `CHIAVE=valore` (letto da systemd, mai
        copiato nello store): TVH_USER, TVH_PASSWORD, JELLYFIN_API_KEY.
        Tutte opzionali: i controlli corrispondenti vengono saltati se vuote.
      '';
    };

    routerSshKey = mkOption {
      type = types.str;
      default = "/root/.ssh/id_rsa_router";
      description = "Chiave privata SSH (di root) usata per configurare il router.";
    };

    routerHostKey = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "ssh-ed25519 AAAA...";
      description = ''
        Chiave pubblica host del router (da `ssh-keyscan -t ed25519 <routerIp>`),
        registrata in known_hosts. Se null devi accettare la chiave a mano una volta:
        `sudo ssh -i <routerSshKey> root@<routerIp>`.
      '';
    };

    tbs = {
      enable = mkEnableOption "hook di sospensione per le schede DVB TBS PCIe (tbsecp3)";
      pciAddresses = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "0000:03:00.0" "0000:04:00.0" ];
        description = "Indirizzi PCI delle schede (`lspci -D | grep -i tbs`), al massimo due.";
      };
      tvheadendUnit = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "tvheadend.service";
        description = ''
          Unit systemd di tvheadend (es. container Quadlet/Podman), fermata
          prima della sospensione e riavviata al risveglio con systemctl.
          Se null si usa un container Docker chiamato "tvheadend".
        '';
      };
    };
  };

  config = mkIf cfg.enable (lib.mkMerge [
    {
      assertions = [
        {
          assertion = builtins.length cfg.tbs.pciAddresses <= 2;
          message = "services.autoSusWol.tbs.pciAddresses: lo script gestisce al massimo due schede.";
        }
      ];

      environment.etc."monitor-ports.conf".text = portsConf;

      systemd.services.check-traffic = {
        description = "Hibernation traffic control";
        serviceConfig = {
          Type = "oneshot";
          User = "root";
          ExecStart = lib.getExe checkTraffic;
        } // lib.optionalAttrs (cfg.environmentFile != null) {
          EnvironmentFile = cfg.environmentFile;
        };
      };

      systemd.timers.check-traffic = {
        description = "Runs traffic check every 5 minutes";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "5min";
        };
      };

      systemd.services.apply-monitor-rules = {
        description = "Apply firewall monitoring rules on boot";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        # Se cambia la lista porte, a ogni switch le regole vengono riapplicate.
        restartTriggers = [ config.environment.etc."monitor-ports.conf".source ];
        unitConfig = {
          StartLimitIntervalSec = 60;
          StartLimitBurst = 3;
        };
        path = [ pkgs.iputils ];
        preStart = ''
          for _ in $(seq 1 90); do
            ping -c1 -W1 ${cfg.routerIp} >/dev/null 2>&1 && exit 0
            sleep 2
          done
          echo "router ${cfg.routerIp} non raggiungibile" >&2
          exit 1
        '';
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = lib.getExe applyRules;
          Restart = "on-failure";
          RestartSec = 10;
        };
      };

      programs.ssh.knownHosts = mkIf (cfg.routerHostKey != null) {
        autosuswol-router = {
          hostNames = [ cfg.routerIp ];
          publicKey = cfg.routerHostKey;
        };
      };
    }

    (mkIf cfg.manageWol {
      networking.interfaces.${cfg.nic}.wakeOnLan.enable = true;
    })

    # Al posto di /usr/lib/systemd/system-sleep/tbsecp3-reset.sh:
    # ExecStart gira all'ingresso in sospensione, ExecStop al risveglio.
    (mkIf cfg.tbs.enable {
      systemd.services.tbsecp3-reset = {
        description = "Reset TBS DVB PCIe tuners around suspend";
        wantedBy = [ "sleep.target" ];
        before = [ "sleep.target" ];
        unitConfig.StopWhenUnneeded = true;
        environment = lib.optionalAttrs (cfg.tbs.tvheadendUnit != null) {
          TVH_UNIT = cfg.tbs.tvheadendUnit;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${lib.getExe tbsReset} pre";
          ExecStop = "${lib.getExe tbsReset} post";
        };
      };
    })
  ]);
}
