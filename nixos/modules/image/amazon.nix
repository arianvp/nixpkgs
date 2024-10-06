{ pkgs, config, lib, ... }: {
  imports = [ ./repart.nix ];
  options = {
    image.amazon.type = lib.mkOption {
      type = lib.types.enum [ "uefi-preferred" "uefi" ];
      default =
        if pkgs.hostPlatform.isAarch64 then "uefi" else "uefi-preferred";
    };
  };

  config = {
    boot.loader.grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      devices = [ "/dev/vda" ];
    };
    boot.initrd.systemd = { enable = true; };
    fileSystems."/" = {
      fsType = "ext4";
      device = "/dev/disk/by-partlabel/root";
    };
    # Grows on first boot
    systemd.repart.partitions = { "10-root".repartConfig.Type = "root"; };
    image.repart = {
      name = config.system.name;
      partitions = {
        "00-esp" = {
          repartConfig = {
            Type = "esp";
            Format = "vfat";
            SizeMinBytes = "1G";
            SizeMaxBytes = "1G";
          };
        };
        "05-bios" = lib.mkIf (config.image.amazon.type == "uefi-preferred") {
          repartConfig = {
            Type = "21686148-6449-6e6f-744e-656564454649";
            SizeMinBytes = "1M";
            SizeMaxBytes = "1M";
          };
        };
        "10-root" = {
          storePaths = [ config.system.build.toplevel ];
          contents = { "/etc/NIXOS".source = pkgs.writeText "NIXOS" ""; };
          repartConfig = {
            Type = "root";
            Label = "root";
            Format = config.fileSystems."/".fsType;
            Minimize = "guess";
          };
        };
      };
    };

    system.build.finalImage = if config.image.amazon.type == "uefi" then
      config.system.build.image
    else
      pkgs.vmTools.runInLinuxVM (pkgs.runCommand config.system.build.image.name {
        preVM = ''
          cp ${config.system.build.image}/${config.image.repart.imageFile} ${config.image.repart.imageFile}
          chmod u+w ${config.image.repart.imageFile}
          diskImage=${config.image.repart.imageFile}
        '';
        postVM = ''
          mkdir -p $out
          cp $diskImage $out/${config.image.repart.imageFile}
        '';
        buildInputs = with pkgs; [ nixos-enter util-linux dosfstools ];
      } ''
        rootDisk=/dev/vda3
        mkdir /dev/block
        ln -s /dev/vda1 /dev/block/254:1
        mountPoint=/mnt
        mkdir $mountPoint
        mount $rootDisk $mountPoint
        mkdir -p $mountPoint/boot
        mount /dev/vda1 $mountPoint/boot

        export HOME=$TMPDIR

        # make profile. Wish this was done outside of the VM
        mkdir -p $mountPoint/nix/var/nix/profiles
        ln -s ${config.system.build.toplevel} $mountPoint/nix/var/nix/profiles/system-1-link 
        ln -s /nix/var/nix/profiles/system-1-link $mountPoint/nix/var/nix/profiles/system 
        ls -l $mountPoint/nix/var/nix/profiles

        NIXOS_INSTALL_BOOTLOADER=1 nixos-enter --root $mountPoint -- ${config.system.build.toplevel}/bin/switch-to-configuration boot
      '');
  };
}
