{
  pkgs,
  yants,
}: let
  plib = import ../../nix/lib {inherit pkgs yants;};

  # CASE 1: single service → $out has exactly one slice + one service,
  #         content matches render output (with @@PROJECT@@ placeholders).
  case1 = let
    project = plib.mkProject {
      services = {
        web = {command = ["/bin/w"];};
      };
    };
    expectedSlice = plib.render.slice {projectId = "@@PROJECT@@";};
    expectedWeb = plib.render.service {
      projectId = "@@PROJECT@@";
      name = "web";
      service = {command = ["/bin/w"];};
    };
  in
    pkgs.runCommand "pctl-mkproject-case1"
    {
      drv = project;
      inherit expectedSlice;
      inherit expectedWeb;
      passAsFile = ["expectedSlice" "expectedWeb"];
    } ''
      set -euo pipefail
      got=$(ls "$drv" | sort)
      want=$(printf 'pctl-@@PROJECT@@-web.service\npctl-@@PROJECT@@.slice\n')
      if [ "$got" != "$want" ]; then
        echo "FAIL: file listing mismatch"
        echo "got:"
        echo "$got"
        echo "want:"
        echo "$want"
        exit 1
      fi
      diff -u "$expectedSlicePath" "$drv/pctl-@@PROJECT@@.slice"
      diff -u "$expectedWebPath" "$drv/pctl-@@PROJECT@@-web.service"
      mkdir -p "$out"
      cp -r "$drv"/* "$out/"
    '';
  # CASE 3: dependsOn referencing a service that doesn't exist → mkProject throws.
  case3 = let
    attempt = builtins.tryEval (plib.mkProject {
      services = {
        web = {
          command = ["/bin/w"];
          dependsOn = ["nonexistent"];
        };
      };
    });
  in
    pkgs.runCommand "pctl-mkproject-case3"
    {
      success =
        if attempt.success
        then "1"
        else "0";
    } ''
      set -euo pipefail
      if [ "$success" = "1" ]; then
        echo "FAIL: expected mkProject to throw for missing dependsOn target"
        exit 1
      fi
      mkdir -p "$out"
      echo ok > "$out/ok"
    '';

  # CASE 4: yants schema enforcement — command must be list<string>.
  case4 = let
    attempt = builtins.tryEval (plib.mkProject {
      services = {
        web = {command = "not-a-list";};
      };
    });
  in
    pkgs.runCommand "pctl-mkproject-case4"
    {
      success =
        if attempt.success
        then "1"
        else "0";
    } ''
      set -euo pipefail
      if [ "$success" = "1" ]; then
        echo "FAIL: expected yants to reject command = \"not-a-list\""
        exit 1
      fi
      mkdir -p "$out"
      echo ok > "$out/ok"
    '';

  # CASE 2: dependsOn wiring → web.service contains Requires= + After=
  #         referencing db's unit with @@PROJECT@@ placeholder.
  case2 = let
    project = plib.mkProject {
      services = {
        db = {command = ["/bin/db"];};
        web = {
          command = ["/bin/w"];
          dependsOn = ["db"];
        };
      };
    };
  in
    pkgs.runCommand "pctl-mkproject-case2"
    {
      drv = project;
    } ''
      set -euo pipefail
      webFile="$drv/pctl-@@PROJECT@@-web.service"
      if ! grep -Fxq 'Requires=pctl-@@PROJECT@@-db.service' "$webFile"; then
        echo "FAIL: missing Requires line"; cat "$webFile"; exit 1
      fi
      if ! grep -Fxq 'After=pctl-@@PROJECT@@-db.service' "$webFile"; then
        echo "FAIL: missing After line"; cat "$webFile"; exit 1
      fi
      mkdir -p "$out"
      cp "$webFile" "$out/"
    '';
in
  pkgs.symlinkJoin {
    name = "pctl-mkproject-tests";
    paths = [case1 case2 case3 case4];
  }
