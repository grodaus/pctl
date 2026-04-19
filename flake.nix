{
  description = "pctl — declarative Nix spec → systemd --user units";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # yants stays: nix/lib/mkProject.nix + nix/lib/types.nix still validate
    # the Nix-level spec shape before emitting spec.json (Q11).
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
        inherit (pkgs) ocamlPackages;

        # pctl's Nix-side library — exposed both as `flake.lib.${system}`
        # (the frozen public contract tuor uses) and internally here for
        # `fixtures` below. Same import; single source of truth.
        pctlLib = import ./nix/lib {
          inherit pkgs yants;
        };

        # Spec-fixture derivations used by the OCaml Phase 2 unit tests.
        # Each is a `pkgs.writeText` whose outPath IS the spec.json file.
        # Committed into test/unit/fixtures/spec/*.json; regenerate with
        #   nix build --no-link --print-out-paths '.#fixtures.<name>'
        # See nix/fixtures.nix for the commit/regeneration recipe.
        fixtures = import ./nix/fixtures.nix {inherit pctlLib;};

        # Phase 0 scaffold build: dune-built OCaml binary. Real sources
        # ship in Phase 1+. Build inputs mirror the lib set declared in
        # docs/src/plans/20260419-ocaml-rewrite.md.
        pctlPkg = ocamlPackages.buildDunePackage {
          pname = "pctl";
          version = "0.0.1";
          duneVersion = "3";
          src = ./.;

          nativeBuildInputs = [pkgs.pkg-config];

          # libsystemd for the Phase 3 sd-bus ctypes bindings. Unused
          # at Phase 0 but linked now so Phase 3 just flips a dune stanza.
          # alcotest/qcheck are test-only but we keep them in buildInputs
          # so `nix develop` exposes them for local `dune test` runs.
          buildInputs =
            [pkgs.systemdLibs]
            ++ (with ocamlPackages; [
              alcotest
              qcheck-core
              qcheck-alcotest
            ]);

          propagatedBuildInputs = with ocamlPackages; [
            eio
            eio_main
            caqti
            caqti-eio
            caqti-driver-sqlite3
            ctypes
            yojson
            ppx_deriving_yojson
            ppx_blob
            cmdliner
            logs
            digestif
          ];

          # `ocaml-build` in `checks` below builds without tests to keep the
          # smoke-test derivation small. The Phase 1 alcotest/qcheck suite
          # runs in a separate `ocaml-tests` check (see below) so a pure
          # library drift in tests doesn't break the binary build.
          doCheck = false;

          checkInputs = with ocamlPackages; [
            alcotest
            qcheck-core
            qcheck-alcotest
          ];

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

        # Fixture derivations surfaced as `.#fixtures.<name>`; see
        # nix/fixtures.nix for the regeneration recipe. Phase-2
        # Spec-loader tests consume the checked-in JSON under
        # test/unit/fixtures/spec/, not these — exposing them keeps
        # regeneration trivial.
        packages.fixtures-single = fixtures.single;
        packages.fixtures-multi = fixtures.multi;
        packages.fixtures-probe = fixtures.probe;
        packages.fixtures-workspace = fixtures.workspace;

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

        # Phase 0: the only check is that the OCaml scaffold compiles.
        # The old Nushell-era checks (test-types / test-render /
        # test-mkproject / test-nu) are deleted because render.nix is
        # gone and mkProject.nix now emits spec.json — their fixtures
        # no longer match.
        #
        # TODO:
        #   Phase 1 → add `ocaml-unit` running `dune runtest` (alcotest + qcheck).
        #   Phase 2 → add `ocaml-spec` covering spec.json parse + SQLite roundtrip.
        #   Phase 3 → add `ocaml-integration` (in-process Fake Systemctl).
        #   Phase 3+ → e2e alias runs on the host, NOT in `nix flake check`
        #              (requires systemd --user; exposed via .forgejo/workflows/ci.yml e2e job).
        #   Phase 4+ → add a Nix-side `spec-json-schema` check once spec.json
        #              has fixtures worth validating from Nix.
        checks = {
          ocaml-build = pctlPkg;
          # Phase 1: alcotest + qcheck suite for the pure core
          # (schema, identity, render, manifest). Runs `dune test` in a
          # separate derivation so failures surface independently from the
          # binary build.
          ocaml-tests = pctlPkg.overrideAttrs (_old: {
            pname = "pctl-tests";
            doCheck = true;
          });
        };
      };

      flake = {
        # `lib` is per-system because mkProject bakes in `pkgs` (for
        # `pkgs.writeText` that emits spec.json, Q11). Consumers call
        # `pctl.lib.${system}.mkProject { services = { ... }; }` —
        # this is a frozen public contract (see plan "Public contracts").
        lib = nixpkgs.lib.genAttrs ["x86_64-linux" "aarch64-linux"] (sys:
          import ./nix/lib {
            pkgs = nixpkgs.legacyPackages.${sys};
            inherit yants;
          });
      };
    };
}
