{
  stdenvNoCC,
  fetchFromGitHub,
  buildFHSEnv,
  coreutils,
  curl,
  openssh,
  cacert,
  gnugrep,
  util-linux,
  openssl,
  gawk,
  gnused,
}:
let
  ec2-instance-connect-script = stdenvNoCC.mkDerivation (prevAttrs: {
    pname = "ec2-instance-connect";
    version = "1.1.17";
    src = fetchFromGitHub {
      owner = "aws";
      repo = "aws-ec2-instance-connect-config";
      rev = prevAttrs.version;
      hash = "sha256-XXrVcmgsYFOj/1cD45ulFry5gY7XOkyhmDV7yXvgNhI=";
    };

    dontBuild = true;
    dontPatchShebangs = true;
    dontPatch = true;

    installPhase = ''
      mkdir -p $out/bin
      cp $src/src/bin/eic_parse_authorized_keys $out/bin
      cp $src/src/bin/eic_run_authorized_keys $out/bin
      # TODO: move to fixup phase!
      sed "s%^ca_path=/etc/ssl/certs$%ca_path=/etc/ssl/certs/ca-bundle.crt%" "src/bin/eic_curl_authorized_keys" > "$out/bin/eic_curl_authorized_keys"
      chmod a+x  "$out/bin/eic_curl_authorized_keys"
    '';
  });
in
buildFHSEnv {
  name = "eic_run_authorized_keys";
  runScript = "${ec2-instance-connect-script}/bin/eic_run_authorized_keys";
  targetPkgs =
    p: with p; [
      coreutils
      curl
      openssh
      cacert
      gnugrep
      util-linux
      openssl
      gawk
      gnused
    ];
}
