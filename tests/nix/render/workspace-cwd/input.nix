{
  projectId = "@@PROJECT@@";
  services = {
    web = {
      command = ["/nix/store/fake/bin/web"];
      workspace.cwd = true;
    };
  };
  expected = {
    "pctl-@@PROJECT@@-web.service" = ''
      [Unit]
      Description=pctl service web

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
      WorkingDirectory=@@PROJECT_PATH@@

      [Install]
      WantedBy=pctl-@@PROJECT@@.target
    '';
  };
}
