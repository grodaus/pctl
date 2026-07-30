# pctl

Declarative Nix spec → systemd `--user` unit materializer.

## Terminology

**Read [UBIQUITOUS_LANGUAGE.md](./UBIQUITOUS_LANGUAGE.md) before writing code or docs.** It defines every domain term (**project**, **slice**, **store tree**, **drop-in**, **manifest**, **project id**, **host**, **registry**, **worktree**, reload actions `+/~/=/-`) and flags terms that look generic but have a specific meaning here (e.g. **host** always means the allocated 127.0.0.N, not the dev machine).

## Layout

OCaml single binary driven by `dune`. Nix-side library stays in `nix/lib/` as the frozen public contract.

- `bin/pctl.ml` — cmdliner entrypoint.
- `lib/` — schema, spec loader, render, systemctl port (+ dbus adapter + in-memory fake), unit_store port (+ fs adapter + in-memory fake), state (SQLite via caqti-eio), lifecycle, plan, probe, gc, identity, clock, nix_build, cli.
- `nix/lib/` — `mkProject.nix`, `types.nix`, `sandbox-defaults.nix`, `default.nix`. Emits `spec.json` via `pkgs.writeText`; OCaml consumes it.
- `migrations/` — SQL applied at startup.
- `templates/init/` — scaffold for `pctl init`.
- `docs/src/plans/20260419-ocaml-rewrite.md` — architecture + locked decisions.

## Tests

Three layers, all in OCaml (dune + alcotest + qcheck):

- **Pure / unit** (`test/unit/`) — alcotest + qcheck property tests over the pure core (schema, identity, manifest, render). Sandbox-safe.
- **Integration** (`test/integration/`) — in-process tests against the Fake Systemctl adapter (alcotest-eio). Sandbox-safe.
- **Reality / e2e** (`test/e2e/`, dune alias `e2e`) — exercises real `systemd --user`. Needs a live user session, so the *only* place it can't run is the Nix sandbox (which is why it's excluded from `nix flake check`). An interactive session on the host almost always has one — confirm with `systemctl --user is-system-running` and run it. Do NOT assume it's unavailable and skip it.

Run with:

- `dune test` runs the two sandbox-safe layers (unit + integration). The same suite is surfaced by the `ocaml-tests` check in `nix flake check`.
- `dune build @e2e` (or `dune build @e2e --force` to re-run) runs the real-systemd suite on the host. Run it before claiming any e2e-affecting change works — when working interactively, a live user session is the norm, not the exception.

Each reality test uses a unique tmpdir → unique **project id** → unique **slice**, so tests don't collide with each other or with the dev's real projects on the same session. `Harness.teardown` (run via `with_scratch`) takes the project down and clears any `failed` tombstone on its slice.
