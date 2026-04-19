# Spec fixtures — drives nix/lib/mkProject.nix with a handful of
# minimal service-spec shapes to produce spec.json files usable as
# OCaml-side unit-test inputs.
#
# Usage (from flake root):
#
#   nix build --no-link --print-out-paths \
#     '.#fixtures.single' '.#fixtures.multi' \
#     '.#fixtures.probe'  '.#fixtures.workspace'
#
# Each output is the `pkgs.writeText` derivation produced by mkProject;
# its outPath IS the spec.json file. Regenerate into the fixtures dir:
#
#   for n in single multi probe workspace; do
#     install -m 644 $(nix build --no-link --print-out-paths ".#fixtures.$n") \
#       "test/unit/fixtures/spec/$n.json"
#   done
#
# Every service uses /bin/true as ExecStart — we're only validating
# JSON shape, not runtime behaviour.
{pctlLib}: {
  single = pctlLib.mkProject {
    services = {
      pg = {
        command = ["/bin/true"];
      };
    };
  };

  multi = pctlLib.mkProject {
    services = {
      migrate = {
        command = ["/bin/true"];
      };
      pg = {
        command = ["/bin/true"];
        dependsOn = ["migrate"];
      };
      server = {
        command = ["/bin/true"];
        dependsOn = ["pg" "migrate"];
      };
    };
  };

  probe = pctlLib.mkProject {
    services = {
      pg = {
        command = ["/bin/true"];
        readinessProbe = {
          exec = ["/bin/true"];
          periodSeconds = 2;
          timeoutSeconds = 60;
        };
      };
    };
  };

  workspace = pctlLib.mkProject {
    services = {
      worker = {
        command = ["/bin/true"];
        workspace = {
          cwd = true;
          writable = true;
        };
      };
    };
  };
}
