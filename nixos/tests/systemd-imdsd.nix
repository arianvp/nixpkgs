{pkgs, ...}:
let
  inherit (import ./ssh-keys.nix pkgs)
    snakeOilPrivateKey
    snakeOilPublicKey
    ;
in
{
  name = "systemd-imdsd";

  nodes =
    let
      metaJson = (pkgs.formats.json { }).generate "aemm.json" {
        metadata = {
          values = {
            hostname = "ip-172-16-34-43.ec2.internal";
            local-hostname = "ip-172-16-34-43.ec2.internal";
            local-ipv4 = "172.16.34.43";
            public-hostname = "ec2-192-0-2-54.compute-1.amazonaws.com";
            public-ipv4 = "192.0.2.54";
            public-key = snakeOilPublicKey;
          };
        };
        userdata = {
          values = {
            userdata = "MTIzNCxqb2huLHJlYm9vdCx0cnVlCg==";
          };
        };
      };
    in
    {

      machine =
        { lib, ... }:
        {
          virtualisation.vlans = [ 1 ];

          # Drop the default user-mode NAT NIC so the guest looks like EC2:
          # a single interface on a single network where IMDS is reachable.
          virtualisation.qemu.networkingOptions = lib.mkForce [ ];

          networking.useNetworkd = true;

          # networking.hostName = "";

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


          systemd.additionalUpstreamSystemUnits = [
            "systemd-imds-early-network.service"
            "systemd-imdsd.socket"
            "systemd-imdsd@.service"
            "systemd-imds-import.service"
            # TODO: requires https://github.com/systemd/systemd/pull/43073
            # "systemd-firstboot.service"
          ];

          # TODO: upstream
          # NOTE: needed to get the ssh key provisioned correctly
          systemd.services.systemd-imds-import.before = [ "systemd-tmpfiles-setup.service" ];

          # we do terribly things with systemd when this is false
          # system.etc.overlay.enable = true;

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
            serviceConfig.ExecStart = "${lib.getExe pkgs.ec2-metadata-mock} -I --hostname 0.0.0.0 --port 80 --config-file ${metaJson}";
          };
        };
    };

  testScript = ''
    start_all()
    metadata.wait_for_unit("ec2-metadata-mock.service")
    metadata.wait_for_open_port(80, "169.254.169.254")
    machine.wait_for_unit("systemd-imds-early-network.service")
    machine.wait_for_unit("systemd-imdsd.socket")
    machine.wait_for_unit("systemd-imds-import.service")
    machine.succeed("/run/current-system/systemd/lib/systemd/systemd-imds --well-known=region")
    machine.succeed("/run/current-system/systemd/lib/systemd/systemd-imds --well-known=zone")
    machine.succeed("/run/current-system/systemd/lib/systemd/systemd-imds --well-known=ipv4-public")
    machine.succeed("/run/current-system/systemd/lib/systemd/systemd-imds --well-known=ssh-key")

    found = machine.succeed("cat /root/.ssh/authorized_keys")
    t.assertEqual(found, "${snakeOilPublicKey}")
  '';
}
