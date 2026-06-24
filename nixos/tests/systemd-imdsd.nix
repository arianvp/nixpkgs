{
  name = "systemd-imdsd";

  nodes = {

    machine =
      { lib, ... }:
      {
        virtualisation.vlans = [ 1 ];

        # Drop the default user-mode NAT NIC so the guest looks like EC2:
        # a single interface on a single network where IMDS is reachable.
        virtualisation.qemu.networkingOptions = lib.mkForce [ ];

        networking.useNetworkd = true;

        networking.hostName = "";

        networking.interfaces.eth1.ipv4.routes = [
          {
            address = "169.254.169.254";
            prefixLength = 32;
            via = "192.168.1.2";
          }
        ];
        users.users.systemd-imds = {
          isSystemUser = true;
          group = "systemd-imds";
        };
        users.groups.systemd-imds = { };

        # TODO: write a test
        # boot.initrd.systemd.additionalUpstreamUnits = [
        #   "systemd-imds-early-network.service"
        #   "systemd-imdsd.socket"
        #   "systemd-imdsd@.service"
        #   "systemd-imds-import.service"
        # ];

        systemd.additionalUpstreamSystemUnits = [
          "systemd-imds-early-network.service"
          "systemd-imdsd.socket"
          "systemd-imdsd@.service"
          "systemd-imds-import.service"
          "systemd-firstboot.service"
        ];

        # we do terribly things with systemd when this is false
        system.etc.overlay.enable = true;

        # by default it uses hwdb but there is no entry for qemu
        # maybe fake one instead? but for now use kernel params
        boot.kernelParams = [
          "systemd.imds=1"
          "systemd.imds.import=1" # by default only runs in initrd. TODO: fix the initrd
          "systemd.imds.vendor=amazon-ec2"
          "systemd.imds.token_url=http://169.254.169.254/latest/api/token"
          "systemd.imds.refresh_header_name=X-aws-ec2-metadata-token-ttl-seconds"
          "systemd.imds.data_url=http://169.254.169.254/latest"
          "systemd.imds.token_header_name=X-aws-ec2-metadata-token"
          "systemd.imds.address_ipv4=169.254.169.254"
          "systemd.imds.key.hostname=/meta-data/hostname"
          "systemd.imds.key.region=/meta-data/placement/region"
          "systemd.imds.key.zone=/meta-data/placement/availability-zone"
          "systemd.imds.key.ipv4_public=/meta-data/public-ipv4"
          "systemd.imds.key.ipv6_public=/meta-data/ipv6"
          "systemd.imds.key.ssh_key=/meta-data/public-keys/0/openssh-key"
          "systemd.imds.key.userdata=/user-data"
        ];
        # virtualisation.credentials."imds.vendor".text = "amazon-ec2";
      };

    metadata =
      { lib, pkgs, ... }:
      {
        virtualisation.vlans = [ 1 ];

        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = "169.254.169.254";
            prefixLength = 32;
          }
        ];
        networking.firewall.allowedTCPPorts = [ 80 ];

        systemd.services.ec2-metadata-mock = {
          wantedBy = [ "multi-user.target" ];
          after = [ "network-online.target" ];
          wants = [ "network-online.target" ];
          serviceConfig.ExecStart = "${lib.getExe pkgs.ec2-metadata-mock} -I --hostname 0.0.0.0 --port 80";
        };
      };
  };

  testScript = ''
    start_all()
    metadata.wait_for_unit("ec2-metadata-mock.service")
    metadata.wait_for_open_port(80, "169.254.169.254")
    machine.succeed("curl -fsS http://169.254.169.254/latest/meta-data/")
    machine.wait_for_unit("systemd-imds-early-network.service")
    machine.wait_for_unit("systemd-imdsd.socket")
    machine.wait_for_unit("systemd-imds-import.service")
    machine.wait_for_unit("systemd-firstboot.service")
    machine.wait_for_unit("first-boot-complete.target")
    machine.succeed("/run/current-system/systemd/lib/systemd/systemd-imds --well-known=region")
    machine.succeed("/run/current-system/systemd/lib/systemd/systemd-imds --well-known=zone")
    machine.succeed("/run/current-system/systemd/lib/systemd/systemd-imds --well-known=ipv4-public")
    machine.succeed("/run/current-system/systemd/lib/systemd/systemd-imds --well-known=ssh-key")
  '';
}
