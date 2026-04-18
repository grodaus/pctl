{
  pkgs,
  yants,
}: let
  types = import ../../nix/lib/types.nix {inherit yants;};

  # Positive case: minimal service with only required field.
  minimalService = types.service {command = ["x"];};

  # Positive case: service with a readinessProbe.
  probedService = types.service {
    command = ["x"];
    readinessProbe = {
      exec = ["/bin/true"];
      periodSeconds = 1;
      timeoutSeconds = 10;
    };
  };

  # Negative case: readinessProbe.exec must be list<string>.
  badProbeAttempt = builtins.tryEval (types.service {
    command = ["x"];
    readinessProbe = {exec = "not-a-list";};
  });

  # Positive case: service with a workspace struct.
  workspaceService = types.service {
    command = ["x"];
    workspace = {
      cwd = true;
      writable = true;
    };
  };

  # Negative case: workspace.cwd must be bool.
  badWorkspaceAttempt = builtins.tryEval (types.service {
    command = ["x"];
    workspace = {cwd = "yes";};
  });
in
  pkgs.runCommand "pctl-test-types"
  {
    badProbeSucceeded =
      if badProbeAttempt.success
      then "1"
      else "0";
    badWorkspaceSucceeded =
      if badWorkspaceAttempt.success
      then "1"
      else "0";
  } ''
    set -euo pipefail
    if [ "$badProbeSucceeded" = "1" ]; then
      echo "FAIL: expected yants to reject readinessProbe.exec = \"not-a-list\""
      exit 1
    fi
    if [ "$badWorkspaceSucceeded" = "1" ]; then
      echo "FAIL: expected yants to reject workspace.cwd = \"yes\""
      exit 1
    fi
    cat > $out <<EOF
    minimalService.command = ${builtins.toJSON minimalService.command}
    probedService.readinessProbe.exec = ${builtins.toJSON probedService.readinessProbe.exec}
    workspaceService.workspace.cwd = ${builtins.toJSON workspaceService.workspace.cwd}
    EOF
  ''
