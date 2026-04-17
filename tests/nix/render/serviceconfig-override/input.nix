{
  projectId = "@@PROJECT@@";
  services = {
    web = {
      command = ["/nix/store/fake/bin/web"];
      serviceConfig = {
        ProtectHome = "no";
        CustomKey = "42";
      };
    };
  };
  expected = {
    "pctl-@@PROJECT@@-web.service" = ''
      [Unit]
      Description=pctl service web

      [Service]
      CustomKey=42
      ExecStart=/nix/store/fake/bin/web
      NoNewPrivileges=yes
      ProtectControlGroups=yes
      ProtectHome=no
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
