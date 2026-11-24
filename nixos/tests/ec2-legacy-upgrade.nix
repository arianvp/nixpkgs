# An instance launched from an AMI built before the image moved to
# systemd-repart has a GRUB-only legacy+gpt disk: a BIOS boot partition and an
# ext4 root that holds /boot. Check that switching it to a configuration that
# imports the image module keeps it bootable.
{
  config,
  lib,
  hostPkgs,
  ...
}:

let
  pkgs = config.node.pkgs;

  common = {
    imports = [
      ../modules/testing/test-instrumentation.nix
      ../modules/profiles/qemu-guest.nix
    ];
    # The serial console is occupied by the test driver's backdoor.
    systemd.services."serial-getty@ttyS0".enable = lib.mkForce false;
    # There is no instance metadata service; this test is about the boot loader.
    systemd.services.fetch-ec2-metadata.enable = false;
    services.amazon-ssm-agent.enable = lib.mkForce false;
    virtualisation.amazon-init.enable = false;
    # There is no network either, so don't wait for a DHCP lease.
    networking.dhcpcd.enable = false;
    # The boot loaders install to /dev/xvda, which QEMU calls /dev/vda.
    boot.initrd.services.udev.rules = ''
      KERNEL=="vda", SYMLINK+="xvda"
    '';
    services.udev.extraRules = ''
      KERNEL=="vda", SYMLINK+="xvda"
    '';
    nixpkgs.pkgs = pkgs;
  };

  imageModule = stateVersion: {
    inheritParentConfig = false;
    configuration = {
      imports = [
        common
        ../maintainers/scripts/ec2/amazon-image.nix
      ];
      system.stateVersion = stateVersion;
      environment.etc.generation.text = "image-module-${stateVersion}";
    };
  };

  legacyCfg =
    (import ../lib/eval-config.nix {
      system = null;
      modules = [
        common
        # What /etc/nixos/configuration.nix on those AMIs imports.
        ../modules/virtualisation/amazon-image.nix
        {
          system.stateVersion = "25.05";
          specialisation.upgraded = imageModule "25.05";
        }
      ];
    }).config;

  legacyImage = import ../lib/make-disk-image.nix {
    inherit lib pkgs;
    config = legacyCfg;
    name = "amazon-legacy-image";
    format = "qcow2";
    fsType = "ext4";
    partitionTableType = "legacy+gpt";
    diskSize = "auto";
    copyChannel = false;
  };

  specialisation = name: legacyCfg.specialisation.${name}.configuration.system.build.toplevel;
in
{
  name = "ec2-legacy-upgrade";
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

    original = "${legacyCfg.system.build.toplevel}"
    upgraded = "${specialisation "upgraded"}"

    disk = os.path.join(os.environ["TMPDIR"], "disk.qcow2")
    subprocess.check_call([
        "${hostPkgs.qemu_test}/bin/qemu-img", "create", "-f", "qcow2", "-F", "qcow2",
        "-b", "${legacyImage}/nixos.qcow2", disk,
    ])
    machine = create_machine(
        "${hostPkgs.qemu_test}/bin/qemu-kvm -m 1024 -nic none"
        f" -drive file={disk},if=virtio,werror=report"
    )

    def boot():
        machine.start()
        # A broken boot loader stops before the kernel, so don't wait for userspace.
        machine.wait_for_console_text(
            r"Linux version|PANIC|grub rescue|error: ", timeout=datetime.timedelta(seconds=20)
        )
        boot_loader_output = machine.get_console_log().split("Linux version")[0]
        failure = re.search(r"PANIC.*|grub rescue.*|error: .*", boot_loader_output)
        if failure is not None:
            raise Exception(f"the boot loader failed: {failure.group(0)}")
        machine.wait_for_unit("multi-user.target", timeout=datetime.timedelta(seconds=60))

    def reboot():
        machine.shutdown()
        boot()

    def assert_booted(system):
        machine.succeed(f"test $(readlink -f /run/booted-system) = {system}")

    def assert_grub_in_mbr():
        machine.succeed("dd if=/dev/vda bs=512 count=1 2>/dev/null | grep -aq GRUB")

    def install(system):
        machine.succeed(f"nix-env -p /nix/var/nix/profiles/system --set {system}")
        status, output = machine.execute(f"{system}/bin/switch-to-configuration boot 2>&1")
        machine.log(output)
        return status

    # The driver does not clean up machines from create_machine, and a VM
    # stuck in its boot loader never powers off.
    try:
        boot()

        with subtest("the legacy image boots with GRUB and has no ESP"):
            assert_booted(original)
            assert_grub_in_mbr()
            machine.fail("findmnt /boot")
            machine.fail("test -e /dev/disk/by-label/ESP")

        with subtest("switching to the image module keeps GRUB"):
            assert install(upgraded) == 0, "switch-to-configuration boot failed"
            assert_grub_in_mbr()
            machine.fail("test -e /boot/limine")
            machine.fail(f"grep by-label/ESP {upgraded}/etc/fstab")

        with subtest("the instance reboots into the new generation"):
            reboot()
            assert_booted(upgraded)
            machine.succeed("grep -x image-module-25.05 /etc/generation")

    finally:
        machine.crash()
  '';
}
