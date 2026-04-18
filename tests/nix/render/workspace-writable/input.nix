{
  projectId = "@@PROJECT@@";
  services = {
    web = {
      command = ["/nix/store/fake/bin/web"];
      workspace.writable = true;
    };
  };
  expected = {
    "pctl-@@PROJECT@@-web.service" = ''
      [Unit]
      Description=pctl service web

      [Service]
      BindPaths=@@PROJECT_PATH@@
      ExecStart=/nix/store/fake/bin/web
      NoNewPrivileges=yes
      ProtectControlGroups=yes
      ProtectHome=tmpfs
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
