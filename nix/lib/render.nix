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
