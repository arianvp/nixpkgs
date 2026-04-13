let
  trustDomain = "example.com";
in
{
  name = "spire";

  nodes = {
    server =
      { config, ... }:
      {
        networking.domain = trustDomain;
        systemd.tmpfiles.settings."10-spire-tpm" = {
          "/var/lib/spire/server/tpm-hashes".f = {
            mode = "0644";
          };
        };
        services.spire.server = {
          enable = true;
          openFirewall = true;
          settings = {
            server.trust_domain = trustDomain;
            plugins = {
              KeyManager.memory.plugin_data = { };
              DataStore.sql.plugin_data = {
                database_type = "sqlite3";
                connection_string = "$STATE_DIRECTORY/datastore.sqlite3";
              };
              NodeAttestor.join_token.plugin_data = { };
              NodeAttestor.tpm.plugin_data.hash_path = "/var/lib/spire/server/tpm-hashes";
            };
          };
        };
      };

    agent = {
      virtualisation.credentials = {
        "spire.join_token".source = "./join_token";
        "spire.trust_bundle".source = "./trust_bundle";
      };

      systemd.services.spire-agent.serviceConfig.ImportCredential = [
        "spire.join_token"
        "spire.trust_bundle"
      ];

      services.spire.agent = {
        enable = true;
        settings = {
          agent = {
            trust_domain = trustDomain;
            server_address = "server.${trustDomain}";
            join_token_file = "$CREDENTIALS_DIRECTORY/spire.join_token";
            trust_bundle_format = "pem";
            trust_bundle_path = "$CREDENTIALS_DIRECTORY/spire.trust_bundle";
          };
          plugins = {
            KeyManager.memory.plugin_data = { };
            NodeAttestor.join_token.plugin_data = { };
            WorkloadAttestor.systemd.plugin_data = { };
            WorkloadAttestor.unix.plugin_data = { };
          };
        };
      };
    };

    tpmAgent =
      { pkgs, ... }:
      {
        virtualisation = {
          useEFIBoot = true;
          tpm.enable = true;
        };

        virtualisation.credentials = {
          "spire.trust_bundle".source = "./trust_bundle";
        };

        systemd.services.spire-agent.serviceConfig.ImportCredential = [
          "spire.trust_bundle"
        ];

        environment.systemPackages = [ pkgs.spire-tpm-plugin ];

        services.spire.agent = {
          enable = true;
          settings = {
            agent = {
              trust_domain = trustDomain;
              server_address = "server.${trustDomain}";
              trust_bundle_format = "pem";
              trust_bundle_path = "$CREDENTIALS_DIRECTORY/spire.trust_bundle";
            };
            plugins = {
              KeyManager.memory.plugin_data = { };
              NodeAttestor.tpm.plugin_data = { };
              WorkloadAttestor.systemd.plugin_data = { };
              WorkloadAttestor.unix.plugin_data = { };
            };
          };
        };
      };
  };

  testScript =
    { nodes, ... }:
    let
      adminSocket = nodes.server.services.spire.server.settings.server.socket_path;
      workloadSocket = nodes.agent.services.spire.agent.settings.agent.socket_path;
      tpmWorkloadSocket = nodes.tpmAgent.services.spire.agent.settings.agent.socket_path;
    in
    ''
      # TODO: instead of trust bundle to talk to the spire-server, use an upstream CA?
      def provision(agent, spiffe_id):

        # expose as system credentials
        bundle = server.succeed("spire-server bundle show -socketPath ${adminSocket}")
        with open(agent.state_dir / "trust_bundle", "w") as f:
          f.write(bundle)
        join_token = server.succeed("spire-server token generate -socketPath ${adminSocket}").split()[1]
        with open(agent.state_dir / "join_token", "w") as f:
          f.write(join_token)

        # register a workload on the node
        parent_id=f"spiffe://${trustDomain}/spire/agent/join_token/{join_token}"
        server.succeed(f"spire-server entry create -socketPath ${adminSocket} -selector 'systemd:id:backdoor.service' -parentID {parent_id} -spiffeID 'spiffe://${trustDomain}/service/backdoor'")

      with subtest("SPIRE server startup and health checks"):
        server.wait_for_unit("spire-server.service")
        server.wait_until_succeeds("spire-server healthcheck -socketPath ${adminSocket}", timeout=30)


      with subtest("Setup SPIRE agent on agent node"):
        provision(agent, "spiffe://${trustDomain}/server/agent")
        agent.wait_for_unit("spire-agent.service")
        agent.wait_until_succeeds("spire-agent healthcheck -socketPath ${workloadSocket}", timeout=90)


      with subtest("Test certificate authentication from agent node"):
        agent.succeed("spire-agent api fetch x509 -socketPath ${workloadSocket} -write .")

      with subtest("Setup SPIRE agent with TPM attestation"):
        # Provision trust bundle before starting the tpmAgent VM
        bundle = server.succeed("spire-server bundle show -socketPath ${adminSocket}")
        with open(tpmAgent.state_dir / "trust_bundle", "w") as f:
          f.write(bundle)

        # Boot the tpmAgent and get the EK hash
        tpmAgent.wait_for_unit("multi-user.target")
        ek_hash = tpmAgent.succeed("get_tpm_pubhash").strip()

        # Enroll the EK hash on the server and restart it
        server.succeed(f"echo '{ek_hash}' > /var/lib/spire/server/tpm-hashes")
        server.succeed("systemctl restart spire-server.service")
        server.wait_until_succeeds("spire-server healthcheck -socketPath ${adminSocket}", timeout=30)

        # Re-provision trust bundle (server restart may regenerate keys) and restart agent
        bundle = server.succeed("spire-server bundle show -socketPath ${adminSocket}")
        with open(tpmAgent.state_dir / "trust_bundle", "w") as f:
          f.write(bundle)
        tpmAgent.succeed("systemctl restart spire-agent.service")

        # Register a workload entry using the TPM agent's SPIFFE ID as parent
        parent_id = f"spiffe://${trustDomain}/spire/agent/tpm/{ek_hash}"
        server.succeed(f"spire-server entry create -socketPath ${adminSocket} -selector 'systemd:id:backdoor.service' -parentID '{parent_id}' -spiffeID 'spiffe://${trustDomain}/service/tpm-backdoor'")

        tpmAgent.wait_for_unit("spire-agent.service")
        tpmAgent.wait_until_succeeds("spire-agent healthcheck -socketPath ${tpmWorkloadSocket}", timeout=90)

      with subtest("Test certificate authentication from TPM agent node"):
        tpmAgent.succeed("spire-agent api fetch x509 -socketPath ${tpmWorkloadSocket} -write .")

      # TODO: Add something to communicate with
    '';
}
