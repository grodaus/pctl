{
  projectId = "@@PROJECT@@";
  services = {
    web = {
      command = ["/nix/store/fake/bin/x"];
      env = {
        FOO = "bar";
        BAZ = "qux";
      };
    };
  };
  expected = {
    "pctl-@@PROJECT@@-web.service" = ''
      [Unit]
      Description=pctl service web

      [Service]
      Environment=BAZ=qux
      Environment=FOO=bar
      ExecStart=/nix/store/fake/bin/x
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
