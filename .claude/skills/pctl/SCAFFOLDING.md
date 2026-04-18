# Scaffolding a new pctl project

## One-shot with `nix run`

From an empty directory:

```sh
nix run github:grodaus/pctl -- init
```

`init` writes `flake.nix` (based on the pctl template) and `.gitignore`. Pass `--force` to overwrite an existing `flake.nix`.

The generated `flake.nix` declares `packages.${system}.pctl = pctl.lib.${system}.mkProject { services = { ... }; }` with a minimal `darkhttpd` example. Edit the `services` block to match your project.

## Putting `pctl` on PATH for the project

For day-to-day use, adding pctl to the project's devshell is more ergonomic than `nix run github:grodaus/pctl -- up` every time. Extend the generated flake:

```nix
{
  description = "a pctl project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    pctl.url = "github:grodaus/pctl";
    pctl.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {nixpkgs, pctl}: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    packages.${system}.pctl = pctl.lib.${system}.mkProject {
      services = {
        web = {
          command = ["${pkgs.darkhttpd}/bin/darkhttpd" "." "--addr" "\${PCTL_HOST}" "--port" "8080"];
        };
      };
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [pctl.packages.${system}.default];
    };
  };
}
```

Now `nix develop` (or `direnv` with `use flake`) puts `pctl` on PATH. Calls become `pctl up` / `pctl reload` / `pctl down`.

## First run

```sh
nix develop              # or: direnv allow, if you use nix-direnv
pctl up                  # builds .#pctl, installs units, starts the slice
```

Output ends with `project <id> up · N units · host=127.0.0.N`. After this, the daily loop is edit-spec → `pctl reload` (see SKILL.md).

## Notes on the template

- The template uses `"\${PCTL_HOST}"` escaped so the literal string `${PCTL_HOST}` reaches the generated unit file; systemd substitutes it at service start. Do **not** interpolate `$PCTL_HOST` in Nix — pctl's drop-in sets it in the service environment, but Nix evaluation can't see it.
- `pctl.inputs.nixpkgs.follows = "nixpkgs"` keeps the closure small and avoids pulling a second nixpkgs.
- Only `x86_64-linux` and `aarch64-linux` are supported.

## See also

- [SKILL.md](${CLAUDE_SKILL_DIR}/SKILL.md) — daily loop once the project is scaffolded.
- [SPEC.md](${CLAUDE_SKILL_DIR}/SPEC.md) — every field of a service, sandbox defaults, placeholder substitutions.
