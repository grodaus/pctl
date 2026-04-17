{
  pkgs,
  yants,
}: let
  types = import ../../nix/lib/types.nix {inherit yants;};

  # Positive case: minimal service with only required field.
  minimalService = types.service {command = ["x"];};
in
  pkgs.runCommand "pctl-test-types" {} ''
    cat > $out <<EOF
    minimalService.command = ${builtins.toJSON minimalService.command}
    EOF
  ''
