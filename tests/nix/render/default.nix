{
  pkgs,
  yants,
}: let
  lib = import ../../../nix/lib {inherit pkgs yants;};

  entries = builtins.readDir ./.;
  caseNames = builtins.filter (n: entries.${n} == "directory") (builtins.attrNames entries);

  renderUnit = projectId: services: unitName:
    if pkgs.lib.hasSuffix ".slice" unitName
    then lib.render.slice {inherit projectId;}
    else let
      serviceName = let
        stripPrefix = pkgs.lib.removePrefix "pctl-${projectId}-" unitName;
      in
        pkgs.lib.removeSuffix ".service" stripPrefix;
    in
      lib.render.service {
        inherit projectId;
        name = serviceName;
        service = services.${serviceName};
      };

  mkCase = caseName: let
    caseDir = ./. + "/${caseName}";
    input = import (caseDir + "/input.nix");
    unitNames = builtins.attrNames input.expected;
    mkUnitCheck = unitName: let
      expected = input.expected.${unitName};
      actual = renderUnit input.projectId (input.services or {}) unitName;
    in
      pkgs.runCommand "pctl-render-${caseName}-${unitName}"
      {
        inherit expected;
        inherit actual;
        passAsFile = ["expected" "actual"];
      } ''
        diff -u "$expectedPath" "$actualPath"
        mkdir -p "$out/${caseName}"
        cp "$actualPath" "$out/${caseName}/${unitName}"
      '';
  in
    pkgs.symlinkJoin {
      name = "pctl-render-${caseName}";
      paths = map mkUnitCheck unitNames;
    };
in
  pkgs.symlinkJoin {
    name = "pctl-render-tests";
    paths = map mkCase caseNames;
  }
