{
  pkgs,
  yants,
}: let
  types = import ./types.nix {inherit yants;};
  # `render.nix` is deleted in Phase 0 of the OCaml rewrite — unit-file
  # rendering moved into OCaml (`lib/render/`). `sandbox-defaults.nix`
  # stays as a Nix-side include consumed by `mkProject` when it merges
  # the per-service `service_config` for spec.json emission.
  mkProject = import ./mkProject.nix {inherit pkgs types;};
in {
  inherit types mkProject;
}
