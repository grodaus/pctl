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
    sortedKeys = builtins.sort (a: b: a < b) (builtins.attrNames kv);
    body = lib.concatMapStrings (k: renderLine k kv.${k}) sortedKeys;
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
    depAttrs =
      if deps == []
      then {}
      else {
        After = depUnits;
        Requires = depUnits;
      };

    unitSection =
      {
        Description = "pctl service ${name}";
      }
      // depAttrs;

    execStart = lib.concatStringsSep " " service.command;

    envAttrs = service.env or {};
    envKeys = builtins.sort (a: b: a < b) (builtins.attrNames envAttrs);
    envLines = map (k: "${k}=${envAttrs.${k}}") envKeys;
    envAttr =
      if envLines == []
      then {}
      else {Environment = envLines;};

    restartAttr =
      if service ? restart
      then {Restart = service.restart;}
      else {};

    limitsAttrs = let
      l = service.limits or {};
    in
      (
        if l ? memoryMax
        then {MemoryMax = l.memoryMax;}
        else {}
      )
      // (
        if l ? cpuQuota
        then {CPUQuota = l.cpuQuota;}
        else {}
      );

    overrideAttrs = service.serviceConfig or {};

    serviceSection =
      sandboxDefaults
      // {
        ExecStart = execStart;
        Slice = sliceName;
      }
      // envAttr // restartAttr // limitsAttrs // overrideAttrs;

    installSection = {
      WantedBy = targetName;
    };
  in
    joinSections [
      (renderSection "Unit" unitSection)
      (renderSection "Service" serviceSection)
      (renderSection "Install" installSection)
    ];
in {
  inherit slice service;
}
