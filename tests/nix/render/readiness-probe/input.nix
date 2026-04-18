{
  projectId = "@@PROJECT@@";
  services = {
    web = {
      command = ["/nix/store/fake/bin/x" "--flag"];
      readinessProbe = {
        exec = ["/nix/store/fake/bin/curl" "-sf" "http://$PCTL_HOST:8080/health"];
        periodSeconds = 1;
        timeoutSeconds = 30;
      };
    };
  };
  # Expected output MUST be identical to minimal-service: the probe is a
  # side-car consumed by `pctl up --wait`, never rendered into the systemd unit.
  expected = {
    "pctl-@@PROJECT@@-web.service" = ''
      [Unit]
      Description=pctl service web

      [Service]
      ExecStart=/nix/store/fake/bin/x --flag
      NoNewPrivileges=yes
      ProtectControlGroups=yes
      ProtectHome=read-only
      ProtectKernelModules=yes
      ProtectKernelTunables=yes
      ProtectSystem=strict
      RestrictNamespaces=yes
      RestrictSUIDSGID=yes
      Slice=pctl-@@PROJECT@@.slice

      [Install]
      WantedBy=pctl-@@PROJECT@@.target
    '';
  };
}
