<!--
---
title: OCaml Rewrite
status: draft
created: 2026-04-19
updated: 2026-04-19
---
-->

# OCaml Rewrite

**Created:** 2026-04-19
**Status:** Draft — decisions locked (Q1–Q14 resolved). Ready for Phase 0.

> **2026-04-20 follow-up (issue #4 RFC):** The `Install.write_units` /
> `Plan.apply` / `Projects.diff_manifest` chain described below has been
> consolidated into `lib/lifecycle/` parameterised by the
> `Unit_store` port (`lib/unit_store/`). Post-rewrite limitation #1
> (drop-in-only changes silently skipped the reload diff) is now fixed
> by hashing `main || 0x00 || dropin_or_empty` in the manifest. See
> commits `e31784b..8aa6656`.

## Context

Current `pctl` is a Nushell PoC (<1 day old) that validated the core idea: declarative Nix specs → `systemd --user` units with per-project host/slice isolation. The sole consumer today is [grodaus/tuor](../../../tuor/flake.nix), which exercises:

- Spec shape: `services.{name} = {command, env, dependsOn, workspace.{cwd,writable}, readinessProbe, serviceConfig}`.
- Logical `serviceConfig.StateDirectory` (the renderer scopes it into `pctl-<project id>-<suffix>`).
- CLI: `up --no-block`, `results --timeout N --json`, `logs <svc> -n N`, `host`, `down`, `restart <svc>`.
- Mixed long-running (pg, server, fake-llm) + oneshot (migrate, test-*) services in one project.

An architectural audit of the PoC surfaced six language-independent frictions: implicit Nix↔consumer contract, scattered project state, no systemctl seam for tests, command-scale logic in "helpers", polling readiness waits, duplicated service-name parsing. Rewrite fixes the shape, not just the language.

## Locked decisions

| #   | Decision                          | Choice                                                                         |
| --- | --------------------------------- | ------------------------------------------------------------------------------ |
| Q1  | Daemon?                           | **No.** Single-shot CLI. Each invocation opens its own dbus connection.        |
| Q2  | Abandoned-project cleanup         | **Opportunistic GC** on mutating commands (see Q13).                           |
| Q3  | Nix↔OCaml contract                | **Unified `spec.json`** — one typed document.                                  |
| Q4  | What goes in spec.json            | Narrow: `kind`, `depends_on`, `workspace`, `probe`, `unit_filename`, `service_config` (fully pre-merged by Nix). |
| Q5  | Who renders unit files            | **OCaml.** Nix only emits spec.json; render.nix is deleted.                    |
| Q6  | D-Bus library                     | **sd-bus FFI via `ctypes`.** No obus, no lwt.                                  |
| Q7  | Concurrency library               | **Eio.** Direct style, no monadic infection.                                   |
| Q8  | Readiness wait shape              | **Parallel fibers + event-driven unit-state** (dbus `PropertiesChanged`) + subprocess poll for probes. |
| Q9  | Error propagation                 | **Exceptions** with `exception Pctl_error of error`. Single variant. One catch at `main`. |
| Q10 | On-disk state                     | **SQLite** at `$XDG_STATE_HOME/pctl/state.db`. Session-scoped via `boot_id`. caqti-eio. |
| Q11 | Nix API shape                     | `pkgs.writeText`-produced `spec.json` (path IS the file). yants stays. sandbox-defaults stays in Nix. Placeholders unchanged. |
| Q12 | Testing strategy                  | Three layers (pure / in-process / e2e), **all in OCaml**. Fake Systemctl adapter. 15 e2e tests ported 1:1. |
| Q13 | Opportunistic GC scope            | **B + C** — mutating commands sweep, `PCTL_NO_GC=1` opts out, warn-and-proceed on failure. |
| Q14a| `pctl logs` impl                  | **Shell-out to journalctl.** No sd-journal FFI.                                |
| Q14b| Nix toolchain                     | **`ocamlPackages` from nixpkgs.** No opam2nix.                                 |
| Q14c| CI                                | **Forgejo workflow written in Phase 0.** Deployed when the repo goes up.       |
| —   | Language                          | **OCaml 5.x** (decided pre-grill).                                             |
| —   | Binary layout                     | **Single binary, single mode.** No daemon subcommand.                          |
| —   | Git strategy                      | Fresh branch `ocaml-rewrite`; wholesale merge to main, Nushell tree retired.   |

## Goals

- Typed schema for every boundary: CLI args, Nix↔OCaml contract, SQLite rows, rendered unit bytes. Compiler enforces the six frictions.
- Event-driven readiness via dbus signals; zero polling for unit-state waits.
- Parallel readiness — all services wait concurrently, not sequentially.
- One authoritative SQLite record per project; opportunistic sweep of abandoned projects.
- Preserve public surfaces so tuor's flake input repoint is the only change downstream.

## Non-goals

- Rewriting the Nix side beyond removing `render.nix`. `mkProject`, `types.nix`, `sandbox-defaults.nix` stay.
- New features. Parity with current PoC only.
- A daemon process of any kind.
- Backwards compatibility during the branch phase — tuor pins the branch and merges together.

## Public contracts (frozen across the rewrite)

**Nix spec shape** — unchanged from current PoC. Tuor's flake.nix call site changes zero lines:

```nix
services.<name> = {
  command = [ ... ];                     # required; list of strings (argv)
  env = { KEY = "value"; };              # optional; string-keyed map
  dependsOn = [ "other-service" ];       # optional
  workspace = { cwd = true; writable = true; };  # optional
  readinessProbe = {
    exec = [ ... ];                      # argv; receives PCTL_HOST/PCTL_ID env
    periodSeconds = 1;
    timeoutSeconds = 30;
  };                                     # optional
  serviceConfig = { ... };               # systemd passthrough; logical suffixes only
};
```

**No placeholders** — `@@PROJECT@@` / `@@PROJECT_PATH@@` were removed in spec.json v2. The OCaml renderer computes every id- or path-derived value from the `workspace` flags and the known project id/path.

**Runtime env vars** — `PCTL_ID` in every unit drop-in, `PCTL_HOST` in service drop-ins only.

**CLI argv** (byte-compatible with current):
- `pctl up [--no-block] [--wait] [--timeout SECS] [--tree PATH] [--nix ATTR] [--path DIR]`
- `pctl reload [--tree PATH] [--nix ATTR] [--path DIR]`
- `pctl down [--path DIR]`
- `pctl results [--timeout SECS] [--json] [--path DIR]`
- `pctl logs <svc> [-n N] [--path DIR]`
- `pctl host [--path DIR]`
- `pctl restart <svc> [--path DIR]`
- `pctl status [--path DIR]`
- `pctl list`
- `pctl gc [--yes]`
- `pctl init` (low priority)

**`pctl results --json` wire format** (tuor's `scripts/collect-pctl-artifacts.nu` parses this):

```json
[ { "name": "pg", "state": "active", "elapsed": 123456789, "kind": "simple" } ]
```

`elapsed` is integer nanoseconds. `state` ∈ `{active, failed, inactive, probe-failed, timed-out}`. `kind` ∈ `{probe, unit-state}`. Order matches spec.json service declaration order, **not** completion order.

**`spec.json` schema v2** (Nix emits, OCaml consumes):

```json
{
  "version": 2,
  "slice": { "slice_config": { ... } },
  "services": {
    "pg": {
      "kind": "simple",
      "command": ["/nix/store/.../bin/postgres", "-D", "/var/lib/pg"],
      "depends_on": [],
      "workspace": { "cwd": true, "writable": true },
      "probe": { "exec": [...], "period_seconds": 1, "timeout_seconds": 30 },
      "service_config": {
        "Type": "simple",
        "Restart": "on-failure",
        "StateDirectory": "pg",
        ...
      }
    }
  }
}
```

OCaml rejects any `version` other than 2 (v1 was the placeholder-carrying predecessor; it's now unsupported). `command` is carried as a JSON list (argv); OCaml renders it into the `ExecStart=` line with systemd-correct quoting (embedded spaces are double-quoted, `\`/`"` escaped, `%` doubled), so argument boundaries survive — a newline in any element is rejected at load (and at `nix build`) since it would split the unit directive. `service_config` is merged by Nix (env → Environment=, limits → MemoryMax, user's explicit serviceConfig layered on top, sandbox-defaults filling unspecified hardening) and no longer carries ExecStart. OCaml treats `service_config` as `string → string` — renders ini, applies per-project id prefix to known runtime-dir keys, writes.

Filenames are derived by OCaml — `pctl-<project id>.slice`, `pctl-<project id>-<service name>.service`. `StateDirectory` / `RuntimeDirectory` / `CacheDirectory` / `LogsDirectory` / `ConfigurationDirectory` values the user writes as logical suffixes (`"pg"`, `"server"`) are rendered as `pctl-<project id>-<suffix>` so distinct projects don't collide under `/var/lib` / `/run` etc. Workspace-derived keys (`WorkingDirectory`, `BindPaths`, `ProtectHome=tmpfs`) are produced by the OCaml renderer from `workspace.cwd` / `workspace.writable`, not by Nix.

## Architecture overview

```
┌────────────────────┐                ┌────────────────────┐
│ User's flake.nix   │                │    systemd --user  │
│  inputs.pctl = ... │                │                    │
│  services = {...}  │                │  pctl-<id>.slice   │
└─────────┬──────────┘                │    ├─ pg.service   │
          │ nix build                  │    ├─ ...          │
          ▼                            └─────▲──────────────┘
┌────────────────────┐                       │
│ spec.json (writeText)──┐                   │ sd_bus (dbus)
│ /nix/store/xxx-spec... │                   │
└────────────────────┘                       │
          │                                  │
          ▼                                  │
┌───────────────────────────────────┐        │
│ pctl <cmd> (OCaml single binary) ─┘        │
│   ├─ sd-bus FFI (Systemctl port)           │
│   ├─ Eio fibers (parallel readiness)        │
│   ├─ SQLite (caqti-eio) at state.db         │
│   ├─ Renderer: spec.json → unit bytes       │
│   └─ Installer: user.control/ + drop-ins    │
└───────────────────────────────────┘
```

**One pctl invocation, one dbus connection, one SQLite transaction, no background process.**

## Repo layout

```
pctl/
├── flake.nix                 dune + ocamlPackages + ctypes + libsystemd
├── dune-project
├── nix/lib/                  Nix side (unchanged except render.nix deleted)
│   ├── mkProject.nix         rewritten to emit spec.json via writeText
│   ├── types.nix             yants validation; mirrors spec.json schema
│   └── sandbox-defaults.nix  merges into service_config pre-emission
├── bin/
│   ├── pctl.ml               cmdliner entrypoint → per-command dispatch
│   └── dune
├── lib/
│   ├── schema/               ADTs: action, state, kind, plan_row, spec, error
│   ├── spec/                 spec.json loader + validator
│   ├── render/               spec → unit file bytes (placeholder substitution)
│   ├── systemctl/            Port sig + sd-bus adapter + in-memory fake
│   ├── state/                SQLite via caqti-eio; project/manifest rows
│   ├── install/              unit install + drop-in write into user.control
│   ├── probe/                parallel readiness (Eio fibers + dbus subs)
│   ├── gc/                   opportunistic sweep + explicit purge
│   ├── identity/             project id derivation, host allocation
│   ├── nix_build/            shell-out to `nix build --print-out-paths`
│   └── cli/                  per-command implementations
├── migrations/               SQL files applied at startup
│   └── 001_init.sql
├── test/
│   ├── unit/                 pure tests (alcotest + qcheck)
│   ├── integration/          in-process tests with Fake Systemctl (alcotest-eio)
│   └── e2e/                  reality tests against real systemd --user
│       └── dune              (alias e2e) so `dune test` skips by default
├── docs/src/plans/           this file + successors
├── .forgejo/workflows/ci.yml nix flake check on push/PR
├── UBIQUITOUS_LANGUAGE.md    ported verbatim from current tree
├── CLAUDE.md                 updated for OCaml/dune
└── README.md                 updated
```

## Internal schema

```ocaml
module Schema = struct
  type action = Added | Changed | Unchanged | Removed
  type state  = Active | Inactive | Failed | Activating | Deactivating | Reloading
  type kind   = Simple | Oneshot | Forking | Notify | Dbus | Idle
  type class_ = Live | Orphan | Unknown

  type project_id = private string          (* smart ctor; derive-id *)
  type host       = private string          (* 127.0.0.N *)

  type manifest = (string * string) list    (* unit_filename → sha256 *)

  type plan_row = {
    unit     : string;
    action   : action;
    old_hash : string option;
    new_hash : string option;
  }

  type probe = {
    exec            : string list;
    period_seconds  : int;
    timeout_seconds : int;
  }

  type service_spec = {
    name           : string;                (* outer object key *)
    kind           : kind;
    depends_on     : string list;
    workspace      : { cwd : bool; writable : bool };
    probe          : probe option;
    service_config : (string * string) list;
  }

  type spec = {
    version  : int;                         (* 2 in the current schema *)
    slice    : { slice_config : (string * string) list };
    services : service_spec StringMap.t;
  }

  type result_row = {
    name    : string;
    state   : [`Active | `Failed | `Inactive | `Probe_failed | `Timed_out];
    elapsed : int64;                        (* nanoseconds *)
    kind    : [`Probe | `Unit_state];
  }

  exception Pctl_error of error
  and error =
    | Spec_not_found       of { path : string }
    | Spec_parse           of { path : string; msg : string }
    | Spec_unknown_version of int
    | Nix_build_failed     of { expr : string; exit_code : int; stderr : string }
    | Install_failed       of { path : string; reason : string }
    | Bus_connect_failed   of { msg : string }
    | Unit_op_failed       of { op : string; unit_ : string;
                                error_name : string option; reply : string }
    | Probe_timeout        of { service : string; timeout_ms : int }
    | Identity_invalid     of { path : string; reason : string }
    | Registry_io          of { id : string; reason : string }

  val render_error    : error -> string
  val error_exit_code : error -> int
end
```

A `Probe_exec_failed of { service; msg }` arm was dropped from this listing:
nothing ever constructed it. Reinstating it is tracked by **pctl-j9k**.

This listing is the plan's narrative sketch, not the contract — `Schema.error`
in `lib/schema/schema.ml` is. Read it for shape and the code for truth.

## Systemctl port

```ocaml
module type SYSTEMCTL = sig
  type t

  val connect     : Eio_unix.Stdenv.base -> t
  val start_unit  : t -> unit:string -> unit
  val stop_unit   : t -> unit:string -> unit
  val restart_unit: t -> unit:string -> unit
  val daemon_reload : t -> unit
  val unit_state  : t -> unit:string -> Schema.state
  val subscribe_unit_changes :
    t -> unit:string -> (Schema.state -> unit) -> unit
end

module Dbus  : SYSTEMCTL   (* ctypes bindings to libsystemd sd_bus *)
module InMem : SYSTEMCTL   (* test fake; exposes push APIs for tests *)
```

Eliminates the `PCTL_SYSTEMCTL` env var stub. Integration tests use `InMem`; e2e and production use `Dbus`.

## SQLite schema (v2)

Migrations at `migrations/001_init.sql` + `migrations/002_spec_blob.sql`:

```sql
CREATE TABLE projects (
  id           TEXT PRIMARY KEY,
  path         TEXT NOT NULL,
  host         TEXT,
  started_at   TEXT,
  store_tree   TEXT,
  session_id   TEXT,
  spec_json    TEXT              -- added in v2, persists the full spec.json
);

CREATE INDEX idx_projects_session ON projects(session_id);

CREATE TABLE manifest (
  project_id    TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  unit_filename TEXT NOT NULL,
  sha256        TEXT NOT NULL,
  PRIMARY KEY (project_id, unit_filename)
);

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

INSERT INTO meta (key, value) VALUES ('schema_version', '2'), ('last_boot_id', '');
```

Session scoping on every invocation:

```sql
UPDATE projects
   SET host = NULL, started_at = NULL, store_tree = NULL, session_id = NULL
 WHERE session_id IS NOT NULL AND session_id != :current_boot_id;

UPDATE meta SET value = :current_boot_id WHERE key = 'last_boot_id';
```

`boot_id` = `/proc/sys/kernel/random/boot_id`.

## Readiness wait algorithm

```
Switch.run @@ fun sw ->
  services
  |> List.map (fun svc -> Fiber.fork_promise ~sw (fun () -> wait_service svc))
  |> List.map Promise.await
  |> aggregate_results
```

For each service, `wait_service`:

- Compute per-service deadline = `min(overall_deadline, now + probe.timeout_seconds)`.
- If `probe` declared:
  - `Fiber.first [run_probe_loop; deadline_timer]`.
  - `run_probe_loop` forks the probe command every `period`; first exit-0 wins.
- Else (no probe):
  - Subscribe to `PropertiesChanged` on `pctl-<id>-<svc>.service`.
  - `Fiber.first [unit_state_stream; deadline_timer]`.
  - `active` → success; `failed|inactive` → terminal failure; transient states ignored.
  - No polling — systemd pushes state transitions.

`pctl up --wait` cancels all fibers via the Switch on first failure. `pctl results --json` collects all, never cancels, emits the `result_row` list in spec.json declaration order.

## Phasing

Each phase ends with a working branch tip. No commits until a phase is green (per project convention — no per-cycle baseline commits).

### Phase 0 — Scaffold

- `flake.nix` using nixpkgs `ocamlPackages` (ocaml 5.x, dune 3, eio, caqti, ctypes, yojson, ppx_deriving_yojson, cmdliner, logs, alcotest, qcheck).
- `dune-project`, skeleton `bin/pctl.ml` prints version.
- Lift `nix/lib/` unchanged, then delete `render.nix` and rewrite `mkProject.nix` to emit spec.json via `pkgs.writeText`.
- Port `UBIQUITOUS_LANGUAGE.md`, update `CLAUDE.md`, stub `README.md`.
- Draft `.forgejo/workflows/ci.yml` (runs `nix flake check`).
- **Exit criterion:** `nix build` produces a binary, `pctl --version` runs, `nix flake check` is green (empty test suites).

### Phase 1 — Pure core

- All `Schema` ADTs + `Pctl_error` + render_error + error_exit_code.
- `Identity.derive`: `path → project_id` (port `sanitize-basename` + `hash8`).
- `Host.allocate`: deterministic 127.0.0.N slot from id + taken set.
- `Manifest.diff`: `manifest → manifest → plan_row list`.
- `Render.substitute`: `string → project_id → project_path → string`.
- `Render.service`: `service_spec → project_id → project_path → bytes`.
- `Render.slice`: analogous.
- QCheck properties: diff symmetry, substitution idempotence, id determinism, render round-trip.
- **Exit criterion:** `dune runtest` green; coverage for every ADT.

### Phase 2 — Spec loader + SQLite state

- `Spec.load`: `path → (spec, Pctl_error)`. Rejects unknown version.
- `State`: caqti-eio wrappers over projects/manifest/meta tables.
- `State.session_reset`: runs on every invocation before any other query.
- Migration runner: reads `migrations/*.sql`, applies pending, bumps `schema_version`.
- **Exit criterion:** parse every fixture spec.json; SQLite roundtrip works; session-reset correctly clears stale rows.

### Phase 3 — Systemctl port + dbus adapter

- Module signature `SYSTEMCTL`.
- `InMem` implementation + test suite (every state transition round-trips).
- `Dbus` implementation via ctypes bindings to `sd_bus_*`.
- Smoke test: `Dbus.unit_state` against a known-active system unit.
- **Exit criterion:** `InMem` passes the signature's property suite; `Dbus` hits a real systemd user instance in one e2e test.

### Phase 4 — up / reload / down / restart

- `Install.write_units`: render spec + substitute placeholders → write `.service`/`.slice` to user.control; create `pctl-runtime.conf` drop-ins with PCTL_ID/PCTL_HOST.
- `Plan.compute_and_apply`: diff manifest, use `Systemctl` port to start/stop/restart, `daemon-reload` once.
- `Up/Reload/Down/Restart` commands wired end-to-end.
- E2e parity with `up_test.nu`, `up_idempotent_test.nu`, `reload_test.nu`, `down_test.nu`, `worktree_test.nu`, `workspace_test.nu`.
- **Exit criterion:** all six tests pass under real `systemd --user`.

### Phase 5 — Readiness (up --wait, results)

- `Probe.wait_service`: single-service Eio fiber with per-service deadline.
- `Probe.wait_all`: Switch + parallel fibers, two exposed strategies (throw-first vs collect-all).
- `Results` command emits `result_row list` as JSON matching tuor's wire format byte-for-byte.
- E2e parity with `wait_*_test.nu`, `results_test.nu`, `host_*_test.nu`, `up_no_block_test.nu`, `up_no_wait_test.nu`.
- **Exit criterion:** tuor's `scripts/collect-pctl-artifacts.nu` parses our `results --json` without modification; every ported e2e test green.

### Phase 6 — Remaining commands

- `logs` — shell out to `journalctl --user -u <unit> -n <N>`.
- `host`, `status`, `list`, `init`.
- `gc`: opportunistic sweep on mutating commands; explicit `gc --yes` for full purge.
- `PCTL_NO_GC=1` env var skips sweep.
- **Exit criterion:** tuor's full `just test` green end-to-end.

### Phase 7 — Merge

- Delete `pctl/` (Nushell), `tests/nu/`, `tests/e2e/`, `call-by-hash.md`.
- Update `flake.nix`, `CLAUDE.md`, `README.md` to reflect OCaml-only reality.
- Repoint tuor's `inputs.pctl` to the rewrite branch; run `just test`; verify parity.
- Merge `ocaml-rewrite` → `main` wholesale.
- **Exit criterion:** tuor green on main; no Nushell code remains in pctl.

## Testing layers

| Layer          | Location                 | Tools                         | Nix sandbox? |
| -------------- | ------------------------ | ----------------------------- | ------------ |
| Pure           | `test/unit/`             | alcotest + qcheck             | Yes          |
| In-process     | `test/integration/`      | alcotest-eio + Fake Systemctl | Yes          |
| Reality (e2e)  | `test/e2e/` (alias e2e)  | alcotest-eio + real systemd   | No           |

Fake Systemctl adapter (layer 2) — `Systemctl.In_mem`:
- Hashtbl keyed by unit name → state.
- `start_unit` transitions `inactive → activating → active` with Eio sleeps so subscribers see transitions.
- Its test-only fault-injection and inspection API is listed in that
  module's own header; it has grown since this plan was written, so the
  code is the list.

## Risks + open questions

- **sd-bus FFI via ctypes** — surface area is small (~12 calls), but memory lifecycle (unref messages) needs care. Wrap every fn in a thin OCaml helper that does unref on exit; exercise in `InMem`-vs-`Dbus` parity tests.
- **Eio maturity** — 3 years old, documentation mature, but smaller community than Lwt. Fall-back: if a blocker emerges in Phase 5, swap readiness to `Unix.select` on sd-bus fd + pipe fds (no lib change).
- **`ppx_deriving_yojson` and polymorphic variants** — result_row's `state` and `kind` use polymorphic variants for tuor-compatible JSON; may need `[@deriving yojson { scheme = "polymorphic_variant"; ... }]`. Verify in Phase 1.
- **caqti-eio version availability in nixpkgs pin** — if pin is older than the caqti-eio release, bump nixpkgs or pull a single package from nix-ocaml/nix-overlays.
- **Tuor's `workspace.{cwd,writable}` bind-mount semantics** — currently rendered by `render.nix` into `ProtectHome=tmpfs` + `BindPaths=<project path>` + `WorkingDirectory=<project path>`. OCaml must emit the same directives. Lift the logic into `lib/render/workspace.ml` with explicit unit tests.

## Success criteria

- Tuor's `just test` runs green with `inputs.pctl` pointed at this branch, no other tuor changes.
- Readiness waits for tuor's 6-service project complete in ≤1 dbus event per state transition (measured; no polling loops).
- Zero `PCTL_SYSTEMCTL`-style global test stubs.
- A fresh contributor locates the Nix↔OCaml contract in one module (`lib/spec/`).
- `nix flake check` runs in Nix sandbox (pure + in-process layers); e2e runs on dev host.

## Public-contract breaks

### Phase 0

- **`mkProject` return shape** — the Phase 0 task brief asked for `{ spec = <path>; }` (attrset with a `spec` attribute). I returned the `pkgs.writeText` derivation directly instead, because tuor writes `packages.pctl = mkProject { ... }` and then `nix build .#pctl` — which requires the return value to be a derivation, not a bare attrset. The outPath of the returned derivation IS `pctl-spec.json` (writeText semantics), so OCaml reading `./result` after `nix build` gets the spec.json file directly. If a future phase wants explicit attr access from Nix callers, add `passthru.spec = self` during the `writeText` construction or wrap with `pkgs.runCommand`; tuor's current call site does not need it.
- **Nushell-era `nix flake check`s dropped** — `test-types`, `test-render`, `test-mkproject`, `test-nu` are removed because `render.nix` is deleted and `mkProject.nix` now emits spec.json (old fixtures no longer match). No public contract here — these were repo-internal — but surfaced for transparency. Replacement OCaml checks land per-phase (see TODO comment in `flake.nix`).
- **`render.nix` deleted; `default.nix` no longer exports `render` / `sandbox`** — any downstream reaching into `pctl.lib.${system}.render` or `.sandbox` would break. No known consumer does (tuor does not); if one surfaces in Phase 7 repoint, we add a transitional shim.

## Known limitations (post-rewrite)

Carried into the first released OCaml build — each is acceptable for
tuor's current surface but flagged for future work.

1. **Manifest tracks only main-unit sha, not drop-ins.** The `manifest`
   table hashes the rendered `.slice`/`.service` bytes; the
   `pctl-runtime.conf` drop-in that carries PCTL_HOST/PCTL_ID is not
   hashed. A drop-in change on its own does not show up in
   `pctl reload`'s diff, so the user must `pctl down && pctl up` to
   pick up a drop-in-only change. In practice the drop-in only changes
   when `host` changes, which does trigger a main-unit rewrite — but
   making this explicit is a future consistency win.
2. **Two Nushell oracle tests not explicitly ported.** The prior
   Nushell suite's `wait_failed_oneshot_test` and
   `wait_overall_timeout_test` exercised readiness failure modes on
   oneshot units. The OCaml rewrite's `test_wait_timeout.ml` covers
   the overall-timeout case; the oneshot-failure case is covered only
   by the `test_results.ml` "fail" service exiting non-zero. If we
   ever want to assert the exact error-code path (bucket 6 vs 5) on
   an oneshot-fail specifically, add a dedicated e2e.
3. **100 ms dispatch-loop granularity for unit-state waits.** The sd-
   bus dispatch fiber in `lib/systemctl/dbus.ml` alternates
   `sd_bus_process` + `sd_bus_wait` with a 100 ms timeout. A
   state-transition signal can take up to that long to propagate to a
   `Probe.wait_unit_state` subscriber. A future revision could
   integrate the bus fd into Eio's epoll loop for edge-triggered
   dispatch, trimming this to sub-ms.
4. **Tuor `tools/flake.nix` alejandra drift.** Pre-existing,
   unrelated to the OCaml rewrite — tuor's own `tools/flake.nix`
   formatter check complains about alejandra drift against a newer
   alejandra. Documented here so a future contributor doesn't confuse
   it with a pctl-side regression.
