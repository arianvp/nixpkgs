# Switch an instance launched from the Amazon image to a new generation and
# reboot into it, so the boot loader gets reinstalled on a running instance.
{
  config,
  lib,
  hostPkgs,
  bootMode,
  firmware,
  ...
}:

let
  pkgs = config.node.pkgs;

  imageCfg =
    (import ../lib/eval-config.nix {
      system = null;
      modules = [
        ../maintainers/scripts/ec2/amazon-image.nix
        ../modules/testing/test-instrumentation.nix
        ../modules/profiles/qemu-guest.nix
        {
          ec2.bootMode = bootMode;
          amazonImage.format = "qcow2";
          nix.channel.enable = false;
          # The serial console is occupied by the test driver's backdoor.
          systemd.services."serial-getty@ttyS0".enable = lib.mkForce false;
          # There is no instance metadata service or network; this test is about the boot loader.
          systemd.services.fetch-ec2-metadata.enable = false;
          services.amazon-ssm-agent.enable = lib.mkForce false;
          virtualisation.amazon-init.enable = false;
          networking.dhcpcd.enable = false;
          # The boot loaders install to /dev/xvda, which QEMU calls /dev/vda.
          services.udev.extraRules = ''
            KERNEL=="vda", SYMLINK+="xvda"
          '';
          # A different initrd, so the switch has to write new files to the ESP.
          specialisation.next.configuration = {
            boot.initrd.availableKernelModules = [ "dm_mod" ];
            environment.etc.generation.text = "next";
          };
          nixpkgs.pkgs = pkgs;
        }
      ];
    }).config;

  image = "${imageCfg.system.build.amazonImage}/${imageCfg.image.fileName}";
  inherit (imageCfg.boot.loader.efi) efiSysMountPoint;
in
{
  name =
    "ec2-image-switch-"
    + (if imageCfg.boot.loader.limine.enable then "limine-${firmware}" else "systemd-boot");
  meta = {
    maintainers = with lib.maintainers; [ arianvp ];
    timeout = 180;
  };

  nodes = { };

  testScript = ''
    import datetime
    import os
    import re
    import subprocess

    original = "${imageCfg.system.build.toplevel}"
    next_system = "${imageCfg.specialisation.next.configuration.system.build.toplevel}"

    disk = os.path.join(os.environ["TMPDIR"], "disk.qcow2")
    subprocess.check_call([
        "${hostPkgs.qemu_test}/bin/qemu-img", "create", "-f", "qcow2", "-F", "qcow2",
        "-b", "${image}", disk,
    ])
    machine = create_machine(
        "${hostPkgs.qemu_test}/bin/qemu-kvm -m 1024 -nic none"
        ${lib.optionalString (firmware == "uefi") ''
          " -drive if=pflash,format=raw,unit=0,readonly=on,file=${hostPkgs.OVMF.firmware}"
          " -drive if=pflash,format=raw,unit=1,readonly=on,file=${hostPkgs.OVMF.variables}"
        ''}
        f" -drive file={disk},if=virtio,werror=report"
    )

    def boot():
        machine.start()
        # A broken boot loader stops before the kernel, so don't wait for userspace.
        machine.wait_for_console_text(
            r"Linux version|PANIC|error: ", timeout=datetime.timedelta(seconds=20)
        )
        boot_loader_output = machine.get_console_log().split("Linux version")[0]
        failure = re.search(r"PANIC.*|error: .*", boot_loader_output)
        if failure is not None:
            raise Exception(f"the boot loader failed: {failure.group(0)}")
        machine.wait_for_unit("multi-user.target", timeout=datetime.timedelta(seconds=60))

    def reboot():
        machine.shutdown()
        boot()

    def assert_booted(system):
        machine.succeed(f"test $(readlink -f /run/booted-system) = {system}")

    # The driver does not clean up machines from create_machine, and a VM
    # stuck in its boot loader never powers off.
    try:
        boot()

        with subtest("the image boots with ${if firmware == "uefi" then "UEFI" else "legacy BIOS"}"):
            assert_booted(original)
            machine.${if firmware == "uefi" then "succeed" else "fail"}("test -d /sys/firmware/efi")
            machine.succeed("findmnt ${efiSysMountPoint}")

        with subtest("switch-to-configuration boot installs the new generation"):
            machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {next_system}")
            machine.succeed(f"{next_system}/bin/switch-to-configuration boot >&2")
            machine.succeed(f"grep -rqF init={next_system}/init ${efiSysMountPoint}")

        with subtest("the instance reboots into the new generation"):
            reboot()
            assert_booted(next_system)
            machine.succeed("grep -x next /etc/generation")

        with subtest("it can roll back"):
            machine.succeed("nix-env -p /nix/var/nix/profiles/system --rollback")
            machine.succeed(f"{original}/bin/switch-to-configuration boot >&2")
            reboot()
            assert_booted(original)

    finally:
        machine.crash()
  '';
}
