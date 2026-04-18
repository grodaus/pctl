---
name: pctl
description: How to use pctl — a Nix → systemd --user service orchestrator — in an existing project. Covers the daily edit/reload/inspect loop, restarting wedged services, the non-negotiables (always reload after spec edits, never touch pctl-managed units via systemctl --user directly), and links to bundled references for scaffolding, the spec schema, and troubleshooting. Use when working in a directory whose flake imports pctl or calls `mkProject`, when running any pctl command (init/up/reload/down/status/logs/restart/list), when editing a mkProject services block, or when the user mentions pctl, PCTL_HOST, PCTL_ID, @@PROJECT@@, a pctl-<id>.slice, or a reload diff (+/~/=/-).
---

# pctl

Declarative Nix spec → systemd `--user` units, one slice per project path.

## Vocabulary

- **Project** — a directory whose flake builds `packages.${system}.pctl = pctl.lib.${system}.mkProject { services = { ... }; }`.
- **Project id** — `<sanitized_basename>_<hash8>`, deterministically derived from the project's absolute path. Appears in every unit name.
- **Slice** — `pctl-<id>.slice`. The cgroup parent of every service in a project.
- **Host** — a `127.0.0.N` loopback address allocated per project so sibling projects never race on ports. Exposed as `$PCTL_HOST`.
- **Manifest** — `{ unit-filename: sha256 }` snapshot saved on `up`/`reload`, used as the left side of the next reload diff.
- **Reload diff** — per-unit actions printed as a `+added ~changed =unchanged -removed` summary.

## Mental model

- Every service declared in the spec becomes a systemd `--user` unit grouped under `pctl-<id>.slice`. The id is hashed from the project's absolute path, so worktrees at different paths get different ids, different slices, and different hosts — they never collide.
- `pctl up` is for first-start: allocates a host, materializes unit files into `$XDG_RUNTIME_DIR/systemd/user.control/`, writes a drop-in injecting `PCTL_ID` and `PCTL_HOST`, starts the slice, kicks each service.
- `pctl reload` rebuilds the spec, recomputes the manifest, diffs it against the saved one, and only restarts services whose unit content changed.

## Daily loop

```sh
pctl up              # first run only: build, install, start
pctl up --wait       # like up, but block until each service is ready
# edit flake.nix ...
pctl reload          # minimal restart; prints "+N ~N =N -N" summary
pctl down            # full teardown
```

**Always `reload` after spec edits.** `up` is for first-start — it allocates a host and writes a fresh registry entry. `reload` is the only command that consults the stored manifest for a minimal restart. Running `up` twice is not the right way to apply a change.

`pctl up --wait` blocks until every service is ready — either its declared `readinessProbe.exec` exits 0, or (if no probe) its unit reaches `active`. Overall ceiling is `--timeout` (default 30s); exits non-zero with the failing service named. Use in scripts that need a service listening before the next step runs.

## Inspecting

```sh
pctl status              # slice-level status
pctl status <service>    # one service's status
pctl logs <service>      # journald for a service; -n N for backlog, -f to follow
pctl list                # every pctl project registered on this session
pctl host                # print this project's allocated 127.0.0.N on stdout
```

`pctl host` is useful for shell plumbing: `PCTL_HOST=$(pctl host) curl http://$PCTL_HOST:8080/`. Fails with a clear "not registered" message if the project hasn't been `pctl up`'d.

## Fixing a stuck service

1. `pctl logs <service> -n 200` — read the failure.
2. If the fix is a spec change: edit `flake.nix`, then `pctl reload`.
3. If the fix is a transient runtime issue: `pctl restart <service>`, then `pctl logs <service> -f` to confirm.

## Non-negotiables

- Never call `systemctl --user` or `journalctl --user` directly on `pctl-*` units. Always go through pctl commands — they derive the correct unit name from the project path and keep the registry consistent.
- Never edit files under `$XDG_RUNTIME_DIR/systemd/user.control/pctl-*`. They are overwritten on every `up`/`reload`.
- Every service runs with sandbox defaults (`ProtectSystem=strict`, `ProtectHome=read-only`, `NoNewPrivileges=yes`, and friends). If a service needs to write anywhere, declare `serviceConfig.StateDirectory` / `RuntimeDirectory`. See [SPEC.md](${CLAUDE_SKILL_DIR}/SPEC.md).

## More

- [SCAFFOLDING.md](${CLAUDE_SKILL_DIR}/SCAFFOLDING.md) — create a new pctl project, wire the CLI into its devShell.
- [SPEC.md](${CLAUDE_SKILL_DIR}/SPEC.md) — full `mkProject` service schema, sandbox defaults, placeholder substitutions.
- [TROUBLESHOOTING.md](${CLAUDE_SKILL_DIR}/TROUBLESHOOTING.md) — common error messages and fixes.
