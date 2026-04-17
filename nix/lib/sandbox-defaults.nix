{
  # PrivateTmp= is NOT in the default set: dev projects often sit under /tmp
  # or need to share /tmp with the user. Opt-in via serviceConfig per service.
  NoNewPrivileges = "yes";
  ProtectControlGroups = "yes";
  ProtectHome = "read-only";
  ProtectKernelModules = "yes";
  ProtectKernelTunables = "yes";
  ProtectSystem = "strict";
  RestrictNamespaces = "yes";
  RestrictSUIDSGID = "yes";
}
