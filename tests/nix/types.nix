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
in
  pkgs.runCommand "pctl-test-types"
  {
    badProbeSucceeded =
      if badProbeAttempt.success
      then "1"
      else "0";
  } ''
    set -euo pipefail
    if [ "$badProbeSucceeded" = "1" ]; then
      echo "FAIL: expected yants to reject readinessProbe.exec = \"not-a-list\""
      exit 1
    fi
    cat > $out <<EOF
    minimalService.command = ${builtins.toJSON minimalService.command}
    probedService.readinessProbe.exec = ${builtins.toJSON probedService.readinessProbe.exec}
    EOF
  ''
