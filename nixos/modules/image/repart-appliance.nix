{ modulesPath, ... }:
{
  imports = map (module: "${modulesPath}/${module}") [
    "image/repart.nix"
    "profiles/image-based-appliance.nix"
    "profiles/bashless.nix"
  ];

  boot.initrd.systemd.root = "gpt-auto";
}
