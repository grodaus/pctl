{
  pkgs,
  yants,
}: let
  types = import ./types.nix {inherit yants;};
  sandbox = import ./sandbox-defaults.nix;
  render = import ./render.nix {
    inherit pkgs;
    sandboxDefaults = sandbox;
  };
  mkProject = import ./mkProject.nix {inherit pkgs types render;};
in {
  inherit types sandbox render mkProject;
}
