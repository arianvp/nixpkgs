# Test that attestable AMI PCR prediction matches the actual TPM PCR values
# when booted in a VM with a software TPM.
{ lib, pkgs, ... }:

{
  name = "attestable-ami";

  meta.maintainers = with lib.maintainers; [ arianvp ];

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (config.image.repart.verityStore) partitionIds;
    in
    {
      imports = [ ../modules/image/attestable-ami.nix ];

      virtualisation = {
        directBoot.enable = false;
        mountHostNixStore = false;
        useEFIBoot = true;
        tpm.enable = true;
        # TODO: OVMFFull should arguably be the default for VMs with TPM,
        # since it includes the full set of UEFI features needed for measured boot.
        efi.OVMF = pkgs.OVMFFull.fd;
        fileSystems = lib.mkVMOverride {
          "/" = {
            fsType = "tmpfs";
            options = [ "mode=0755" ];
          };
          "/nix/store" = {
            device = "/usr/nix/store";
            fsType = "none";
            options = [ "bind" ];
          };
        };
      };

      image.repart = {
        name = "attestable-ami";
        # OVMF does not work with the default repart sector size of 4096
        sectorSize = 512;
        verityStore.ukiPath = "/EFI/BOOT/BOOT${lib.toUpper config.nixpkgs.hostPlatform.efiArch}.EFI";
        partitions.${partitionIds.esp}.repartConfig = {
          Type = "esp";
          Format = "vfat";
          SizeMinBytes = if config.nixpkgs.hostPlatform.isx86_64 then "64M" else "96M";
        };
      };

      # TODO: figure out how to remove this. nixos-init reads env_binary from
      # the bootspec and tries to create /usr/bin/env, but the verity store
      # makes /usr read-only. Setting usrbinenv = null removes env_binary from
      # the bootspec entirely. See also: appliance-repart-image-verity-store.nix
      environment.usrbinenv = null;

      environment.systemPackages = [ pkgs.tpm2-tools ];
      system.image.id = "nixos-attestable-ami";
      system.image.version = "1";
    };

  testScript =
    { nodes, ... }:
    let
      machine = nodes.machine;
    in
    # python
    ''
      import json
      import os
      import subprocess
      import tempfile

      with subtest("register-image-params.json is well-formed"):
        with open("${machine.config.system.build.registerImageParams}/nix-support/register-image-params.json") as f:
          params = json.load(f)
        print(f"RegisterImage params: {json.dumps(params, indent=2)}")

        required_keys = {"Name", "Architecture", "BootMode", "TpmSupport",
                         "RootDeviceName", "VirtualizationType", "EnaSupport",
                         "ImdsSupport", "SriovNetSupport", "BlockDeviceMappings"}
        assert required_keys <= params.keys(), \
          f"Missing keys: {required_keys - params.keys()}"

        assert params["BootMode"] == "uefi"
        assert params["TpmSupport"] == "v2.0"
        assert params["VirtualizationType"] == "hvm"

        root_device = params["RootDeviceName"]
        root_mapping = next(
          (m for m in params["BlockDeviceMappings"] if m["DeviceName"] == root_device),
          None,
        )
        assert root_mapping is not None, f"No mapping for root device {root_device!r}"
        assert "SourceImageFile" in root_mapping["Ebs"], \
          "Root device Ebs is missing SourceImageFile"
        assert os.path.exists(root_mapping["Ebs"]["SourceImageFile"]), \
          f"SourceImageFile does not exist: {root_mapping['Ebs']['SourceImageFile']}"

      # Boot the machine using the image referenced by SourceImageFile,
      # proving the path in the JSON is correct.
      image_file = root_mapping["Ebs"]["SourceImageFile"]
      tmp_disk = tempfile.NamedTemporaryFile()
      subprocess.run([
        "${machine.virtualisation.qemu.package}/bin/qemu-img",
        "create", "-f", "qcow2",
        "-b", image_file,
        "-F", "raw",
        tmp_disk.name,
      ], check=True)
      os.environ['NIX_DISK_IMAGE'] = tmp_disk.name

      machine.wait_for_unit("default.target")

      with subtest("TPM device is present"):
        machine.succeed("test -e /dev/tpm0")

      with subtest("Predicted PCRs match actual PCRs"):
        with open("${machine.config.system.build.pcrPrediction}/pcrs.json") as f:
          predicted = json.load(f)
        print(f"Predicted PCRs: {json.dumps(predicted, indent=2)}")

        measurements = predicted["Measurements"]
        hash_alg = measurements["HashAlgorithm"].lower()

        for pcr_index, predicted_value in measurements.items():
          if pcr_index == "HashAlgorithm":
            continue
          pcr_num = pcr_index.removeprefix("PCR")
          actual = machine.succeed(f"tpm2_pcrread {hash_alg}:{pcr_num}").strip()
          print(f"PCR {pcr_num}: predicted={predicted_value}, actual output={actual}")
          assert predicted_value.lower() in actual.lower(), \
            f"PCR {pcr_num} mismatch: predicted {predicted_value}, got {actual}"
    '';
}
