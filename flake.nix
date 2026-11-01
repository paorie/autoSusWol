{
  description = "autoSusWol - sospensione automatica del server e Wake-on-LAN tramite router OpenWrt";

  outputs = { self, ... }: {
    nixosModules.default = import ./nix/module.nix;
    nixosModules.autoSusWol = self.nixosModules.default;
  };
}
