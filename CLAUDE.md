# pctl

Declarative Nix spec → systemd `--user` unit materializer.

## Terminology

**Read [UBIQUITOUS_LANGUAGE.md](./UBIQUITOUS_LANGUAGE.md) before writing code or docs.** It defines every domain term (**project**, **slice**, **store tree**, **drop-in**, **manifest**, **project id**, **host**, **registry**, **worktree**, reload actions `+/~/=/-`) and flags terms that look generic but have a specific meaning here (e.g. **host** always means the allocated 127.0.0.N, not the dev machine).

## Status

**Mid-rewrite.** The repo is being ported from Nushell to OCaml. See [docs/src/plans/20260419-ocaml-rewrite.md](./docs/src/plans/20260419-ocaml-rewrite.md) for the phase-by-phase plan and locked decisions. The Nushell tree (`pctl/`, `tests/nu/`, `tests/e2e/`) is retired wholesale in Phase 7 — do not touch it in OCaml phases.

## Tests

Three layers, all in OCaml (dune + alcotest + qcheck):

- **Pure / unit** (`test/unit/`) — alcotest + qcheck property tests. Runs in the Nix sandbox via `dune runtest` (invoked by `nix flake check` from Phase 1 onwards).
- **Integration** (`test/integration/`) — in-process tests against the Fake Systemctl adapter (`alcotest-eio`). Also sandbox-safe; covered by `dune runtest`.
- **Reality / e2e** (`test/e2e/`, dune alias `e2e`) — real `systemd --user` on the host. Run with `dune test --force @e2e`. Requires a live user session; NOT runnable in the Nix sandbox. Ported 1:1 from the old `tests/e2e/*.nu` suite.

Each reality test uses a unique tmpdir → unique **project id** → unique **slice**, so tests don't collide with each other or with the dev's real projects on the same session. `cleanup_stragglers` sweeps leaked slices at suite start.

Phase 0 scaffold has no tests yet — `nix flake check` only verifies `dune build`. `dune runtest` lands in Phase 1.
