{
  description = "pctl — declarative Nix spec → systemd --user units";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    yants = {
      url = "github:divnix/yants";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs @ {
    nixpkgs,
    yants,
    flake-parts,
    treefmt-nix,
    ...
  }:
    flake-parts.lib.mkFlake {inherit inputs;} {
      systems = ["x86_64-linux" "aarch64-linux"];

      imports = [treefmt-nix.flakeModule];

      perSystem = {pkgs, ...}: let
        pctlPkg = pkgs.stdenv.mkDerivation {
          pname = "pctl";
          version = "0.0.1";
          src = ./.;
          nativeBuildInputs = [pkgs.makeWrapper];
          buildInputs = [pkgs.nushell];
          installPhase = ''
            runHook preInstall
            mkdir -p $out/share/pctl $out/bin
            cp -r pctl templates $out/share/pctl/
            makeWrapper ${pkgs.nushell}/bin/nu $out/bin/pctl \
              --add-flags "$out/share/pctl/pctl/pctl.nu"
            runHook postInstall
          '';
          meta = {
            description = "declarative Nix spec → systemd --user units";
            mainProgram = "pctl";
          };
        };
        appMeta = {
          description = "declarative Nix spec → systemd --user units";
          mainProgram = "pctl";
        };
      in {
        treefmt = {
          projectRootFile = "flake.nix";
          programs.alejandra.enable = true;
          programs.deadnix.enable = true;
          programs.statix.enable = true;
        };

        packages.pctl = pctlPkg;
        packages.default = pctlPkg;

        apps.pctl = {
          type = "app";
          program = "${pctlPkg}/bin/pctl";
          meta = appMeta;
        };
        apps.default = {
          type = "app";
          program = "${pctlPkg}/bin/pctl";
          meta = appMeta;
        };

        checks = {
          test-types = import ./tests/nix/types.nix {inherit pkgs yants;};
          test-render = import ./tests/nix/render {inherit pkgs yants;};
          test-mkproject = import ./tests/nix/mkProject.nix {inherit pkgs yants;};
          test-nu = import ./tests/nu {inherit pkgs;};
        };
      };

      flake = {
        # `lib` is per-system because it bakes in pkgs (for pkgs.runCommand in
        # mkProject and pkgs.lib in render). Consumers do
        # `pctl.lib.${system}.mkProject { ... }`.
        lib = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"] (system:
          import ./nix/lib {
            pkgs = nixpkgs.legacyPackages.${system};
            inherit yants;
          });
      };
    };
}
