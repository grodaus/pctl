# pctl

Worktree-safe Nix → systemd `--user` orchestrator. Declare a project's services in a flake; every checkout gets its own slice, its own `127.0.0.N` loopback host, and zero port collisions with sibling worktrees on the same session.

## Requirements

- Linux with an active `systemd --user` session (pctl refuses to run without `$XDG_RUNTIME_DIR`).
- Nix with flakes enabled.

## Quickstart

Scaffold a project in an empty directory:

```sh
nix run github:grodaus/pctl -- init
```

This writes a `flake.nix` you can edit. To get the `pctl` CLI on your PATH via `nix develop` or `direnv`, add a devshell to that flake:

```nix
devShells.${system}.default = pkgs.mkShell {
  packages = [ pctl.packages.${system}.default ];
};
```

Then the core loop:

```sh
pctl up       # build the spec, install units, start the slice
pctl reload   # re-diff the spec, restart only changed services
pctl down     # stop the slice, remove installed units
```

## Example — postgres + migrate + web

A trimmed `mkProject` spec (full fixture with the `initdb` / `dbmate` shell plumbing lives in `tests/e2e/fixtures/pg/flake.nix`):

```nix
packages.${system}.pctl = pctl.lib.${system}.mkProject {
  services = {
    pg = {
      command = ["${pgRun}/bin/pctl-pg-run"];
      serviceConfig = {
        Type = "simple";
        StateDirectory = "pctl-@@PROJECT@@-pg";
        RuntimeDirectory = "pctl-@@PROJECT@@-pg";
        RuntimeDirectoryPreserve = "yes";
        Restart = "on-failure";
      };
    };

    migrate = {
      command = ["${migrate}/bin/pctl-pg-migrate"];
      dependsOn = ["pg"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
      };
    };

    web = {
      command = ["${web}/bin/pctl-pg-web"];
      dependsOn = ["migrate"];
      env = {
        PG_DATABASE = "app";
        PG_USER = "postgres";
      };
      serviceConfig.Restart = "on-failure";
    };
  };
};
```

Every service receives `PCTL_HOST=127.0.0.N` (allocated per project path) and `PCTL_ID` (the project id) via a systemd drop-in. Reference them as `$PCTL_HOST` in service code, or `${PCTL_HOST}` in systemd unit directives. `@@PROJECT@@` is substituted at install time with the project id.

## Commands

Setup
- `pctl init` — scaffold `flake.nix` and `.gitignore`

Lifecycle
- `pctl up` — build the spec, install units, start the slice
- `pctl down` — stop the slice, remove units, drop the registry entry
- `pctl restart [service]` — restart one service, or the whole slice

Change
- `pctl reload` — diff the new spec against the stored manifest; `+` added, `~` changed, `=` unchanged, `-` removed; restart only what changed

Inspect
- `pctl status [service]` — systemd status for a service, or the slice
- `pctl logs [service]` — tail journald for a service, or the slice
- `pctl list` — every pctl project registered on this session

Every command accepts `--help`.

## How it works

Each project's absolute path is hashed into a **project id**; from that id pctl derives a unique `pctl-<id>.slice` and allocates a `127.0.0.N` loopback **host**. `pctl up` materializes the `mkProject` store tree into `$XDG_RUNTIME_DIR/systemd/user.control/`, writes a drop-in carrying `PCTL_ID` + `PCTL_HOST`, and starts the slice. `pctl reload` hashes the new unit files, diffs against the saved manifest, and issues the minimal set of restarts.

See [UBIQUITOUS_LANGUAGE.md](./UBIQUITOUS_LANGUAGE.md) for the full vocabulary and [call-by-hash.md](./call-by-hash.md) for the design inspiration.

## Status

Early prototype. APIs will change without notice. Not recommended for anything load-bearing yet. Feedback and bug reports welcome via GitHub issues.

## License

MIT — see [LICENSE](./LICENSE).
