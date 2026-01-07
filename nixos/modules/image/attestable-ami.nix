{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    ;

  cfg = config.amazonImage;

  architecture =
    if pkgs.stdenv.hostPlatform.isx86_64 then
      "x86_64"
    else if pkgs.stdenv.hostPlatform.isAarch64 then
      "arm64"
    else
      throw "Unsupported platform for attestable AMI: ${pkgs.stdenv.hostPlatform.system}";

  ebsOptions = types.submodule {
    options = {
      VolumeType = mkOption {
        type = types.str;
        default = "gp3";
      };
      DeleteOnTermination = mkOption {
        type = types.bool;
        default = true;
      };
      VolumeSize = mkOption {
        type = types.nullOr types.int;
        default = null;
        description = "Size in GiB. Defaults to the snapshot size if not specified.";
      };
      Encrypted = mkOption {
        type = types.nullOr types.bool;
        default = null;
      };
      Iops = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      Throughput = mkOption {
        type = types.nullOr types.int;
        default = null;
      };
      SourceImageFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Path to the disk image file to upload as a snapshot.
          Consumed by upload-ami: stripped from the params and replaced
          with the resulting SnapshotId before calling RegisterImage.
        '';
      };
      SourceImageFormat = mkOption {
        type = types.str;
        default = "raw";
        description = ''
          Disk image format for S3-based snapshot import (e.g. raw, VHD).
          Ignored when using EBS Direct upload.
          Consumed by upload-ami alongside SourceImageFile.
        '';
      };
    };
  };

  blockDeviceMappingOptions = types.submodule {
    options = {
      DeviceName = mkOption {
        type = types.str;
      };
      Ebs = mkOption {
        type = types.nullOr ebsOptions;
        default = null;
        description = "EBS-specific parameters. Null for instance store or suppressed mappings.";
      };
      NoDevice = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Set to empty string to suppress this device from the AMI.";
      };
      VirtualName = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Virtual device name for instance store volumes (e.g. ephemeral0).";
      };
    };
  };

  # Strip null fields from an EBS attrset before JSON serialization.
  # SourceImageFile and SourceImageFormat are kept — upload-ami strips them.
  renderEbs =
    ebs:
    lib.filterAttrs (_: v: v != null) {
      inherit (ebs)
        VolumeType
        DeleteOnTermination
        VolumeSize
        Encrypted
        Iops
        Throughput
        SourceImageFile
        SourceImageFormat
        ;
    };

  renderMapping =
    m:
    lib.filterAttrs (_: v: v != null) {
      inherit (m) DeviceName;
      Ebs = if m.Ebs != null then renderEbs m.Ebs else null;
      NoDevice = m.NoDevice;
      VirtualName = m.VirtualName;
    };

  registerImageParams = {
    Name = config.image.baseName;
    Architecture = architecture;
    BootMode = "uefi";
    TpmSupport = "v2.0";
    RootDeviceName = cfg.RootDeviceName;
    VirtualizationType = "hvm";
    EnaSupport = true;
    ImdsSupport = "v2.0";
    SriovNetSupport = "simple";
    BlockDeviceMappings = map renderMapping cfg.BlockDeviceMappings;
  };

  jsonFormat = pkgs.formats.json { };
in
{
  imports = map (module: "${modulesPath}/${module}") [
    "image/repart.nix"
    "profiles/image-based-appliance.nix"
    "profiles/perlless.nix"
  ];

  options.amazonImage = {
    RootDeviceName = mkOption {
      type = types.str;
      default = "/dev/xvda";
    };

    BlockDeviceMappings = mkOption {
      type = types.listOf blockDeviceMappingOptions;
      default = [
        {
          DeviceName = "/dev/xvda";
          Ebs = { };
        }
      ];
      description = ''
        Block device mappings for the AMI. Set `Ebs.SourceImageFile` on any
        EBS mapping to have upload-ami upload that file as a snapshot and
        inject the resulting SnapshotId.
      '';
    };
  };

  config = {
    boot.loader.systemd-boot.enable = true;
    image.repart.verityStore.enable = true;

    # Wire up the root device to the repart image automatically.
    amazonImage.BlockDeviceMappings = lib.mkDefault [
      {
        DeviceName = cfg.RootDeviceName;
        Ebs.SourceImageFile = "${config.system.build.image}/${config.image.filePath}";
      }
    ];

    system.build.pcrPrediction =
      pkgs.runCommand "nitrotpm-pcr-prediction"
        {
          nativeBuildInputs = [ pkgs.buildPackages.nitrotpm-tools ];
        }
        ''
          mkdir -p $out
          nitro-tpm-pcr-compute \
            --image ${config.system.build.uki}/${config.system.boot.loader.ukiFile} \
            | tee $out/pcrs.json
        '';

    system.build.registerImageParams =
      pkgs.runCommand "register-image-params"
        { }
        ''
          mkdir -p $out/nix-support
          cp ${jsonFormat.generate "register-image-params.json" registerImageParams} \
            $out/nix-support/register-image-params.json
        '';

    # KMS key policy statement granting access conditioned on matching PCR
    # measurements from the NitroTPM attestation document.
    #
    # Usage: include this in your KMS key policy when creating the key.
    # At runtime, the instance must call kms:Decrypt (or other operations)
    # with an attestation document obtained via `nitro-tpm-attest`:
    #
    #   private_key=$(openssl genrsa | base64 -w0)
    #   public_key=$(openssl rsa -pubout \
    #       -in <(base64 -d <<< "$private_key") -outform DER 2>/dev/null | base64 -w0)
    #   attestation_doc=$(nitro-tpm-attest \
    #       --public-key <(base64 -d <<< "$public_key") | base64 -w0)
    #   plaintext_cms=$(aws kms decrypt \
    #       --key-id "$KMS_KEY_ID" \
    #       --recipient "KeyEncryptionAlgorithm=RSAES_OAEP_SHA_256,AttestationDocument=$attestation_doc" \
    #       --ciphertext-blob fileb://ciphertext.bin \
    #       --output text --query CiphertextForRecipient)
    #   openssl cms -decrypt \
    #       -inkey <(base64 -d <<< "$private_key") -inform DER \
    #       -in <(base64 -d <<< "$plaintext_cms")
    system.build.kmsKeyPolicy =
      pkgs.runCommand "kms-key-policy"
        {
          nativeBuildInputs = [ pkgs.jq ];
        }
        ''
          mkdir -p $out/nix-support
          jq -n \
            --slurpfile pcrs ${config.system.build.pcrPrediction}/pcrs.json \
            '{
              Version: "2012-10-17",
              Statement: [{
                Sid: "AllowAttestationDecrypt",
                Effect: "Allow",
                Principal: "*",
                Action: [
                  "kms:Decrypt",
                  "kms:DeriveSharedSecret",
                  "kms:GenerateDataKey",
                  "kms:GenerateDataKeyPair",
                  "kms:GenerateRandom"
                ],
                Resource: "*",
                Condition: {
                  StringEqualsIgnoreCase: (
                    $pcrs[0].Measurements
                    | to_entries
                    | map(select(.key != "HashAlgorithm"))
                    | map({
                        key: ("kms:RecipientAttestation:" + .key),
                        value: .value
                      })
                    | from_entries
                  )
                }
              }]
            }' > $out/nix-support/kms-key-policy.json
        '';

    # Make nitro-tpm-attest available on the instance for runtime attestation.
    environment.systemPackages = [ pkgs.nitrotpm-tools ];
  };
}
