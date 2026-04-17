{
  projectId = "@@PROJECT@@";
  services = {
    db = {
      command = ["/nix/store/fake/bin/db"];
    };
    web = {
      command = ["/nix/store/fake/bin/web"];
      dependsOn = ["db"];
    };
  };
  expected = {
    "pctl-@@PROJECT@@-web.service" = ''
      [Unit]
      After=pctl-@@PROJECT@@-db.service
      Description=pctl service web
      Requires=pctl-@@PROJECT@@-db.service

      [Service]
      ExecStart=/nix/store/fake/bin/web
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
