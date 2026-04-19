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

          # git: older nixpkgs ocamlPackages.buildDunePackage runs
          # `dune subst` in installPhase, which requires git on PATH even
          # when there's nothing to subst. Newer nixpkgs skip subst when
          # the dune-project has no version stanza, but tuor's pinned
          # nixpkgs is older and hits this. Cheap to include unconditionally.
          nativeBuildInputs = [pkgs.pkg-config pkgs.git];

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
            ctypes-foreign
            yojson
            ppx_deriving_yojson
            ppx_blob
            cmdliner
            logs
            digestif
            # mtime — Phase 5 Probe module uses Mtime.span / Mtime.add_span
            # to compute per-fiber elapsed nanoseconds and per-service
            # deadlines. Eio depends on mtime already, but we list it
            # explicitly so `Mtime` is exposed to pctl's linking set.
            mtime
            # Render / Identity use `Re` for regex-based placeholder
            # substitution and basename sanitization (replaces the
            # Nushell-parity hand-rolled Buffer state machines).
            re
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

          # `pctl init` reads templates/init/{flake.nix,.gitignore} at
          # runtime. Install them next to the binary so they ship with the
          # Nix build — the OCaml side falls back to $out/share/pctl/templates/init
          # when PCTL_TEMPLATES_DIR is not set.
          postInstall = ''
            mkdir -p "$out/share/pctl/templates/init"
            cp -a templates/init/. "$out/share/pctl/templates/init/"
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

        # `ocaml-build` builds the binary without the test suite.
        # `ocaml-tests` re-uses the same derivation with `doCheck = true`
        # so the alcotest + qcheck + integration suites run in the Nix
        # sandbox. The real-systemd e2e suite (`dune build @e2e`) is NOT
        # exposed here — it requires a live user session and runs on the
        # host / a privileged CI runner (see .forgejo/workflows/ci.yml).
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
