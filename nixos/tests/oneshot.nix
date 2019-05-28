import ./make-test.nix {
  name = "oneshot";

  machine = { pkgs, ...}: {
    systemd.services.hello = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.hello}/bin/hello";
      };
    };
  };
  testScript = ''
    $machine->waitForUnit("hello.service");
  '';
}
