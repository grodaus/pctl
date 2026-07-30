{
  pkgs,
  yants,
}: let
  types = import ./types.nix {inherit yants;};
  # Unit-file rendering lives in OCaml (`lib/render/`); the Nix side only
  # emits spec.json. `sandbox-defaults.nix` is a Nix-side include consumed
  # by `mkProject` when it merges the per-service `service_config`.
  mkProject = import ./mkProject.nix {inherit pkgs types;};
in {
  inherit types mkProject;
}
