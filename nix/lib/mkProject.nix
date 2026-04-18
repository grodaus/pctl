{
  pkgs,
  types,
  render,
}: {services}: let
  inherit (pkgs) lib;

  placeholder = "@@PROJECT@@";

  validated = lib.mapAttrs (_: s: types.service s) services;

  serviceNames = builtins.attrNames validated;

  checkDeps = svcName: svc: let
    deps = svc.dependsOn or [];
    missing = builtins.filter (d: !(builtins.elem d serviceNames)) deps;
  in
    if missing == []
    then null
    else throw "pctl.mkProject: service '${svcName}' dependsOn references unknown service(s): ${lib.concatStringsSep ", " missing}";

  _ = lib.mapAttrsToList checkDeps validated;
  depsChecked = builtins.deepSeq _ validated;

  sliceText = render.slice {projectId = placeholder;};

  serviceFiles =
    lib.mapAttrsToList
    (svcName: svc: {
      fname = "pctl-${placeholder}-${svcName}.service";
      contents = render.service {
        projectId = placeholder;
        name = svcName;
        service = svc;
      };
    })
    depsChecked;

  sliceFile = {
    fname = "pctl-${placeholder}.slice";
    contents = sliceText;
  };

  # Probes are a side-car consumed by `pctl up --wait`, not rendered into any
  # systemd unit. Shape: { <svcName>: { exec, periodSeconds, timeoutSeconds } }.
  probes =
    lib.mapAttrs (_: s: s.readinessProbe)
    (lib.filterAttrs (_: s: s ? readinessProbe) depsChecked);

  probesFile = {
    fname = "probes.json";
    contents = builtins.toJSON probes;
  };

  allFiles = [sliceFile probesFile] ++ serviceFiles;

  envAttrs = lib.listToAttrs (lib.imap0
    (i: f: {
      name = "file${toString i}";
      value = f.contents;
    })
    allFiles);

  installCmds = lib.concatStringsSep "\n" (lib.imap0
    (i: f: ''install -m 0644 "''${file${toString i}Path}" "$out/${f.fname}"'')
    allFiles);

  passNames = lib.imap0 (i: _: "file${toString i}") allFiles;
in
  pkgs.runCommand "pctl-project"
  ({passAsFile = passNames;} // envAttrs)
  ''
    mkdir -p "$out"
    ${installCmds}
  ''
