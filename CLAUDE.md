# pctl

Declarative Nix spec → systemd `--user` unit materializer.

## Terminology

**Read [UBIQUITOUS_LANGUAGE.md](./UBIQUITOUS_LANGUAGE.md) before writing code or docs.** It defines every domain term (**project**, **slice**, **store tree**, **drop-in**, **manifest**, **project id**, **host**, **registry**, **worktree**, reload actions `+/~/=/-`) and flags terms that look generic but have a specific meaning here (e.g. **host** always means the allocated 127.0.0.N, not the dev machine).

## Tests

Two layers:

- **`nix flake check`** — pure Nix tests (`test-types`, `test-render`, `test-mkproject`) and Nushell unit tests (`test-nu`). Hermetic, fast, runs in CI.
- **`nu tests/e2e/run.nu`** — real-systemd e2e suite on the host. Requires `systemd --user`. ~11s total. Not runnable in the Nix sandbox. No mocks.

Each e2e test uses a unique tmpdir → unique **project id** → unique **slice**, so tests don't collide with each other or with the dev's real projects on the same session. `cleanup-stragglers` sweeps leaked slices at suite start.
