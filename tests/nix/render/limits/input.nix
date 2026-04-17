{
  projectId = "@@PROJECT@@";
  services = {
    web = {
      command = ["/nix/store/fake/bin/web"];
      restart = "always";
      limits = {
        memoryMax = "256M";
        cpuQuota = "50%";
      };
    };
  };
  expected = {
    "pctl-@@PROJECT@@-web.service" = ''
      [Unit]
      Description=pctl service web

      [Service]
      CPUQuota=50%
      ExecStart=/nix/store/fake/bin/web
      MemoryMax=256M
      NoNewPrivileges=yes
      ProtectControlGroups=yes
      ProtectHome=read-only
      ProtectKernelModules=yes
      ProtectKernelTunables=yes
      ProtectSystem=strict
      Restart=always
      RestrictNamespaces=yes
      RestrictSUIDSGID=yes
      Slice=pctl-@@PROJECT@@.slice

      [Install]
      WantedBy=pctl-@@PROJECT@@.target
    '';
  };
}
