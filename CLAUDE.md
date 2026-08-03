# pctl

Declarative Nix spec → systemd `--user` unit materializer.

## Terminology

**Read [UBIQUITOUS_LANGUAGE.md](./UBIQUITOUS_LANGUAGE.md) before writing code or docs.** It defines every domain term (**project**, **slice**, **spec file**, **drop-in**, **manifest**, **project id**, **host**, **registry**, **registry row**, **boot id**, **session id**, **worktree**, reload actions `+/~/=/-`) and flags terms that look generic but have a specific meaning here (e.g. **host** always means the allocated 127.0.0.N, not the dev machine; **state dir** is systemd's, not pctl's).

## Layout

OCaml single binary driven by `dune`. Nix-side library stays in `nix/lib/` as the frozen public contract.

- `bin/pctl.ml` — cmdliner entrypoint.
- `lib/` — schema, spec loader, render, systemctl port (+ dbus adapter + in-memory fake), unit_store port (+ fs adapter + in-memory fake), state (SQLite via caqti-eio), lifecycle, plan, probe, gc, identity, clock, nix_build, cli.
- `nix/lib/` — `mkProject.nix`, `types.nix`, `sandbox-defaults.nix`, `default.nix`. Emits `spec.json` via `pkgs.writeText`; OCaml consumes it.
- `migrations/` — SQL applied at startup.
- `templates/init/` — scaffold for `pctl init`.
- `scripts/` — dev-loop helpers that are not part of the build. `e2e-repeat.sh` is the only one; see Tests.
- `docs/src/plans/20260419-ocaml-rewrite.md` — architecture + locked decisions.

## Tests

Three layers, all in OCaml (dune + alcotest + qcheck):

- **Pure / unit** (`test/unit/`) — alcotest + qcheck over one module at a time: the pure core (schema, identity, manifest, render, bus_errors) plus the ports exercised through their in-memory adapters (systemctl/in_mem, unit_store, probe, gc). Sandbox-safe.
- **Integration** (`test/integration/`) — in-process tests that wire several components together, over SQLite and the fake adapters (state, lifecycle, pipeline). Sandbox-safe.
- **Reality / e2e** (`test/e2e/`, dune alias `e2e`) — exercises real `systemd --user`. Needs a live user session, so the *only* place it can't run is the Nix sandbox (which is why it's excluded from `nix flake check`). An interactive session on the host almost always has one — confirm with `systemctl --user is-system-running` and run it. Do NOT assume it's unavailable and skip it.

Run with:

- `dune test` runs the two sandbox-safe layers (unit + integration). The same suite is surfaced by the `ocaml-tests` check in `nix flake check`.
- `dune build @e2e` (or `dune build @e2e --force` to re-run) runs the real-systemd suite on the host. Run it before claiming any e2e-affecting change works — when working interactively, a live user session is the norm, not the exception.
- `scripts/e2e-repeat.sh [runs]` runs that suite N times (default 5) and reports the pass rate. One green `dune build @e2e` is not evidence the gate is stable — the script's header says why. Use this before claiming it is. Its exit codes distinguish the ways a batch can be un-green: 1 a run failed, 2 the runs were skipped rather than executed, 3 every run passed but every one of them reported that a timing-window test never hit its window. Only 0 means the suite ran and proved something.

Each reality test uses a unique tmpdir → unique **project id** → unique **slice**, so tests don't collide with each other or with the dev's real projects on the same session. `Harness.teardown` (run via `with_scratch`) takes the project down and clears any `failed` tombstone on its slice.

Two tests are the exception to "tests only touch their own slice": `test_reload_survives_reexec` and `test_unit_state_survives_reexec` both run `systemctl --user daemon-reexec` against the live session, which is what a `nixos-rebuild switch` does and which running units survive. The first uses a fixed two; the second keeps going until it observes the fault it is looking for, up to its own `max_reexecs`. Both share `test/e2e/reexec.ml` and must be last in the `e2e` alias.
