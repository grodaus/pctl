# Troubleshooting pctl

## `pctl: XDG_RUNTIME_DIR is not set (requires Linux + systemd --user)`

You are on a system without an active systemd user session — macOS, WSL1, a container without systemd, or a sudo/root shell that doesn't inherit the user's runtime dir.

Fix: run pctl as the normal user on a Linux session where `systemctl --user status` works. Check `echo $XDG_RUNTIME_DIR`; it should point to `/run/user/<uid>`.

## `pctl init: flake.nix already exists at <path> — pass --force to overwrite`

`init` refuses to clobber an existing flake. Pass `--force` if the overwrite is intentional, or `cd` to an empty directory.

## `pctl down: no registered project with id '<id>' at <path>`

Either the project was never `up`'d from this path, or the registry entry was lost (typically because `$XDG_RUNTIME_DIR` was cleared on logout and the slice is no longer running anyway). Nothing to tear down.

Verify with `pctl list`. If the slice is actually running but the registry entry is gone, `systemctl --user stop pctl-<id>.slice` is a last-resort fallback — but only reach for it when `pctl down` can't find the project.

## `allocate-host: no free slot in 127.0.0.2..254 for id '<id>'`

You have more than 253 pctl projects running concurrently on this session, which is vanishingly unlikely. More likely: a previous run leaked slices that claim hosts but aren't reachable via `pctl down`. Sweep with `pctl list` to find stale entries; stop them with `pctl down --path <path>` or, as a fallback, `systemctl --user stop pctl-<id>.slice`.

## `nix build failed: ...`

Your `.#pctl` attribute did not build. Run `nix build .#pctl` standalone and read the error. Common causes:

- A `command = [...]` refers to a derivation path that doesn't exist (e.g. typo in `${pkgs.foo}/bin/bar`).
- `yants` rejected a field — the error message names the offending key. Re-check against [SPEC.md](${CLAUDE_SKILL_DIR}/SPEC.md).
- `env` values are not strings. `env.PORT = 8080` fails; use `env.PORT = "8080"`.

## Service enters `failed` state after `up` or `reload`

1. `pctl logs <service> -n 200` to read the failure.
2. If it's an `(code=exited, status=226/NAMESPACE)` or `(status=200/CHDIR)` style error, the sandbox defaults are the cause. Read the systemd unit at `$XDG_RUNTIME_DIR/systemd/user.control/pctl-<id>-<service>.service` (read-only inspection — do not edit) to see the active directives, then add the needed `serviceConfig` escape hatch. Common fixes:
   - Need to write files: `serviceConfig.StateDirectory = "pctl-@@PROJECT@@-<svc>"` (writes go to `$XDG_STATE_HOME/...`).
   - Need to write to a sibling directory under `/home`: `serviceConfig.ProtectHome = "tmpfs"` or `"no"` (loosens the default).
   - Need `/tmp` shared with the session: leave `PrivateTmp` unset (it's not default).
3. After changing `serviceConfig`, `pctl reload`.

## Service keeps restarting, logs look fine

You probably have `restart = "on-failure"` or `"always"` and a process that exits 0 in under a second. systemd's `StartLimitBurst` will eventually enter failed state. Fix the service so it stays alive, or set `restart = "no"` for a one-shot.

Oneshot services should be declared explicitly:

```nix
serviceConfig = {
  Type = "oneshot";
  RemainAfterExit = "yes";
};
```

## `pctl reload` says `+0 ~0 =N -0` but I changed the spec

Nix didn't rebuild. Either the change was purely inside a shell string systemd already substitutes at runtime (e.g. editing code reached via `${writeShellApplication ...}` whose inputs didn't change), or `.#pctl` is cached. Try:

1. `nix build .#pctl --rebuild` to force a rebuild.
2. Confirm the changed file is actually referenced from the flake's closure. Edits to files outside the flake's input set (untracked, or in a path Nix doesn't evaluate) will not trigger a rebuild.

## Worktrees colliding

They shouldn't — pctl derives the id from the absolute project path, and each worktree has a distinct path. If two worktrees share an id, they're actually the same directory (e.g. a symlink to the real checkout). Resolve by invoking pctl from the real path, not via the symlink, or pass `--path` explicitly.

## See also

- [SKILL.md](${CLAUDE_SKILL_DIR}/SKILL.md) — daily loop and non-negotiables.
- [SPEC.md](${CLAUDE_SKILL_DIR}/SPEC.md) — service schema and sandbox defaults.
