{
  pkgs,
  sandboxDefaults,
}: let
  inherit (pkgs) lib;

  renderLine = key: value:
    if builtins.isList value
    then lib.concatMapStrings (v: "${key}=${v}\n") value
    else "${key}=${value}\n";

  renderSection = sectionName: kv: let
    body = lib.concatStrings (lib.mapAttrsToList renderLine kv);
  in "[${sectionName}]\n${body}";

  joinSections = sections: lib.concatStringsSep "\n" sections;

  slice = {projectId}:
    joinSections [
      (renderSection "Unit" {Description = "pctl project ${projectId}";})
      (renderSection "Slice" {})
    ];

  service = {
    projectId,
    name,
    service,
  }: let
    sliceName = "pctl-${projectId}.slice";
    targetName = "pctl-${projectId}.target";

    deps = service.dependsOn or [];
    depUnits = map (d: "pctl-${projectId}-${d}.service") deps;

    unitSection =
      {Description = "pctl service ${name}";}
      // lib.optionalAttrs (deps != []) {
        After = depUnits;
        Requires = depUnits;
      };

    envAttrs = service.env or {};
    envLines = lib.mapAttrsToList (k: v: "${k}=${v}") envAttrs;

    limits = service.limits or {};

    # ProtectHome=tmpfs + BindPaths is strictly tighter than ProtectHome=no:
    # only the project dir is bind-mounted back in, so siblings and the rest
    # of /home stay invisible to the service.
    workspace = service.workspace or {};
    workspaceAttrs =
      lib.optionalAttrs (workspace.cwd or false) {
        WorkingDirectory = "@@PROJECT_PATH@@";
      }
      // lib.optionalAttrs (workspace.writable or false) {
        ProtectHome = "tmpfs";
        BindPaths = ["@@PROJECT_PATH@@"];
      };

    serviceSection =
      sandboxDefaults
      // {
        ExecStart = lib.concatStringsSep " " service.command;
        Slice = sliceName;
      }
      // lib.optionalAttrs (envLines != []) {Environment = envLines;}
      // lib.optionalAttrs (service ? restart) {Restart = service.restart;}
      // lib.optionalAttrs (limits ? memoryMax) {MemoryMax = limits.memoryMax;}
      // lib.optionalAttrs (limits ? cpuQuota) {CPUQuota = limits.cpuQuota;}
      // workspaceAttrs
      // (service.serviceConfig or {});

    installSection = {WantedBy = targetName;};
  in
    joinSections [
      (renderSection "Unit" unitSection)
      (renderSection "Service" serviceSection)
      (renderSection "Install" installSection)
    ];
in {
  inherit slice service;
}
