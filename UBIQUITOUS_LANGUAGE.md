# Ubiquitous Language

This document is the source of truth for pctl's domain terminology. Every term here has a single canonical meaning; flagged synonyms exist only to call out drift that should not appear in code or docs. The OCaml modules under [`lib/`](./lib) implement these concepts — each table lists the primary module for the term where one exists.

## Project lifecycle

_Implemented across [`lib/cli/`](./lib/cli) command modules; shared state in [`lib/state/`](./lib/state)._

| Term              | Definition                                                                                                   | Aliases to avoid        |
| ----------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------- |
| **Project**       | A directory whose flake declares a set of services via `pctl.lib.${system}.mkProject`                        | App                     |
| **Project path**  | Absolute path on disk of a project; the sole input to identity derivation                                    | Cwd, dir                |
| **Spec**          | The declarative Nix expression passed to `mkProject` — a record of named service definitions                 | Config, declaration     |
| **Service**       | A single long-running process declared by the spec (`command`, `env`, `dependsOn`, `limits`, `serviceConfig`)| Process, daemon         |
| **Up**            | Installing units, starting the slice, and starting every service in the project                              | Start, launch           |
| **Reload**        | Recomputing the spec, diffing against the stored manifest, and minimally restarting changed services         | Restart, rebuild        |
| **Down**          | Stopping the slice, removing installed units, dropping the registry entry                                    | Stop, teardown          |

## Artifacts

_Rendered by [`lib/render/`](./lib/render); written to disk by [`lib/unit_store/`](./lib/unit_store); sequenced by [`lib/lifecycle/`](./lib/lifecycle); manifest stored via [`lib/state/`](./lib/state)._

| Term            | Definition                                                                                                                  | Aliases to avoid             |
| --------------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| **Unit**        | A systemd unit file — either a **slice** or a **service** — emitted by pctl                                                 | File, config                 |
| **Slice**       | The `pctl-<id>.slice` that cgroup-parents every service in a project                                                        | Group, namespace             |
| **Spec file**   | The `/nix/store` output of `mkProject`. Because `mkProject` uses `pkgs.writeText`, the outpath IS the `spec.json` file (not a directory). OCaml renders unit files from the spec at install time. Consumed by `up` and `reload`. | Store tree, tree, bundle     |
| **Drop-in**     | The `pctl-runtime.conf` file pctl writes into `<unit>.d/` carrying **PCTL_ID** (+ **PCTL_HOST** on services)                | Override, extension          |
| **Manifest**    | `{ unit-filename: sha256 }` snapshot persisted on `up`/`reload`, used as the left side of the next reload diff              | Hash map, lock file          |
| **User.control**| `$XDG_RUNTIME_DIR/systemd/user.control/` — the live unit directory systemd --user reads, owned by `Unit_store.Fs`          | Runtime dir, unit dir        |

## Identity & allocation

_Derived by [`lib/identity/`](./lib/identity) (project id + host allocation); unit bytes produced in [`lib/render/`](./lib/render), written to disk by [`lib/unit_store/`](./lib/unit_store) and orchestrated by [`lib/lifecycle/`](./lib/lifecycle)._

| Term             | Definition                                                                                                     | Aliases to avoid       |
| ---------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------- |
| **Project id**   | `<sanitized_basename>_<hash8>` deterministically derived from **project path**; appears in every unit name     | Name, slug             |
| **Host**         | A `127.0.0.N` address allocated per project so concurrent projects never race on ports                         | IP, address            |
| **Registry**     | Per-project state at `$XDG_RUNTIME_DIR/pctl/projects/<id>/`: `path`, `host`, `manifest.nuon`, `started_at`. Session-scoped — cleared on reboot. | Store, database |
| **Known marker** | Persistent per-project file at `$XDG_STATE_HOME/pctl/known/<id>` containing the absolute **project path**. Written on `up`, untouched by `down`, survives reboot. The only signal **gc** uses to tell a live project's state from garbage. | —           |
| **PCTL_ID**      | Env var set in every drop-in exposing the **project id** to the service process                                | —                      |
| **PCTL_HOST**    | Env var set in service drop-ins exposing the allocated **host** to the service process                         | —                      |
| **Workspace**    | Per-service spec field `{ cwd?, writable? }` opting into `WorkingDirectory=<project path>` and a `ProtectHome=tmpfs` + `BindPaths=<project path>` write-through. The OCaml renderer computes these values from the flag — users don't write paths directly. | —                      |
| **Logical suffix** | A **service_config** value like `StateDirectory = "pg"` that the OCaml renderer expands to `pctl-<project id>-pg` at install time. Applied to `StateDirectory` / `RuntimeDirectory` / `CacheDirectory` / `LogsDirectory` / `ConfigurationDirectory`. Replaces the pre-v2 `@@PROJECT@@` placeholder convention. | — |
| **Worktree**     | A distinct project path (e.g. a git worktree) whose identity-from-path rule guarantees a distinct **project id**, **slice**, and **host** — letting siblings coexist | Copy, clone |

## Garbage collection

_Implemented in [`lib/gc/`](./lib/gc); known markers written alongside the registry under [`lib/state/`](./lib/state)._

| Term             | Definition                                                                                                                                | Aliases to avoid        |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| **State dir**    | A directory under `$XDG_STATE_HOME` systemd creates from a service's `StateDirectory=<logical suffix>` (the renderer expands it to `pctl-<project id>-<suffix>`) — persists across `down` | StateDirectory, data dir |
| **Gc**           | `pctl gc` — classifies every **state dir** by cross-referencing **known markers**; `--yes` deletes only classified-orphan dirs            | Cleanup, purge          |
| **Live (gc)**    | A **state dir** whose **known marker** points at a **project path** that still exists on disk — kept                                      | Active                  |
| **Orphan (gc)** | A **state dir** whose **known marker** points at a **project path** that no longer exists — the only class `gc --yes` deletes             | Stale, dead             |
| **Unknown (gc)**| A **state dir** with no **known marker** — pre-existing leak or third-party `pctl-*` directory; reported only, never deleted automatically | Foreign                 |

## Reload diff

_Diffed by [`lib/state/`](./lib/state) (`Projects.diff_manifest`); formatted for output by [`lib/plan/`](./lib/plan); applied by [`lib/lifecycle/`](./lib/lifecycle) through the [`lib/systemctl/`](./lib/systemctl) port._

| Term                     | Definition                                                          | Aliases to avoid |
| ------------------------ | ------------------------------------------------------------------- | ---------------- |
| **Plan**                 | The ordered table of `{unit, action, old_hash, new_hash}` rows a diff produces | Diff, changeset  |
| **Action: added (+)**    | Unit present in new **manifest**, absent in old — `start`           | New              |
| **Action: changed (~)**  | Unit in both manifests, hashes differ — `restart`                   | Updated          |
| **Action: unchanged (=)**| Unit in both manifests, hashes equal — no-op                        | Same             |
| **Action: removed (-)**  | Unit absent in new, present in old — `stop` and delete              | Gone, deleted    |

## Readiness

_Implemented in [`lib/probe/`](./lib/probe) (parallel Eio fibers + dbus subscriptions)._

| Term                 | Definition                                                                                                                      | Aliases to avoid           |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| **Readiness probe**  | The `readinessProbe` spec field — an exec argv `pctl up --wait` polls until it exits 0                                          | Healthcheck, liveness probe |
| **Ready**            | A service whose **readiness probe** has exited 0 (or whose unit reached `active`, if no probe is declared)                      | Up, started, healthy       |
| **Wait**             | The `pctl up --wait` mode: after `up` starts every service, block until each is **ready** (or the overall timeout fires)        | Block, await               |

## Testing

_Three layers in [`test/unit/`](./test/unit), [`test/integration/`](./test/integration), [`test/e2e/`](./test/e2e); see [CLAUDE.md](./CLAUDE.md) for run commands._

| Term            | Definition                                                                                                             | Aliases to avoid   |
| --------------- | ---------------------------------------------------------------------------------------------------------------------- | ------------------ |
| **Reality test**| An e2e test run against the host's real `systemd --user`; the only layer that verifies actual activation behaviour     | Smoke test         |
| **Harness**     | Shared setup/teardown helpers in `test/e2e/harness.ml` (`setup`, `with_scratch`, `spec_json`, `wait_active`, `teardown`) | Fixture, helpers   |
| **Scratch**     | The ephemeral record `{tmp, project_dir, spec_path, xdg_state_home, xdg_state_home_prev}` a harness produces for one test | Sandbox, workspace |
| **Straggler**   | A slice left behind on the host session by a crashed test run; each test's `teardown` takes its own project down, but there is no suite-start sweep | Leak, zombie       |

## Relationships

- A **Project** has exactly one **Project id** (pure function of **Project path**) and exactly one allocated **Host**.
- A **Project** owns one **Slice** and zero-or-more **Service** units; every **Service** runs inside its **Project**'s **Slice**.
- `mkProject` produces one **Spec file** per **Spec**; `up` and `reload` both consume a **Spec file**.
- Each installed **Unit** has exactly one **Drop-in** carrying runtime env (**PCTL_ID** on all, **PCTL_HOST** on services only).
- `up` writes one **Registry** entry and one **Manifest**; `reload` reads the **Manifest**, computes a **Plan**, then rewrites both.
- Two **Worktrees** of the same repo have distinct **Project ids** and **Hosts** and therefore distinct **Slices** that coexist on one `systemd --user` session.

## Example dialogue

> **Dev:** "When I run `pctl up`, where does the **spec file** actually come from?"

> **Domain expert:** "`mkProject` reads your **spec** and emits a **spec file** — a single `spec.json` blob (writeText derivation) holding per-service configs as pure logical data. `up` resolves the **project id** from the **project path**, renders one **unit** per service (deriving filenames, `Slice=pctl-<id>.slice`, and any **logical suffix** state/runtime dirs from the id), and writes them into **user.control** along with a **drop-in** per unit carrying **PCTL_ID** and (for services) **PCTL_HOST**."

> **Dev:** "So the **slice** only gets **PCTL_ID**, not **PCTL_HOST**?"

> **Domain expert:** "Right — the **host** is a port-isolation tool for service processes. The **slice** is a cgroup parent, it doesn't bind anything. Only the **service** drop-ins carry **PCTL_HOST**."

> **Dev:** "And **reload** — what changes when I edit one service's command?"

> **Domain expert:** "The new **spec file** produces a new **manifest**. Diffing against the stored **manifest** yields a **plan**: the changed service gets a `~` action, everything else `=`. `reload` runs `systemctl restart` on the `~` units only — the **slice** never bounces."

> **Dev:** "What if I have two **worktrees** of the same repo checked out?"

> **Domain expert:** "Each has a distinct **project path**, so each gets a distinct **project id**, **host**, **slice**, and **registry** entry. They share the `systemd --user` session but never collide — that's the whole point of hashing the path into the **project id**."

## Flagged ambiguities

- **"Tree"** in conversation historically meant `mkProject`'s `/nix/store` output. Since the OCaml rewrite, `mkProject` is a `writeText` derivation whose outpath IS the `spec.json` file — no directory. Canonical term is **Spec file**; avoid "store tree", "tree", "bundle" in code comments and docs.
- **"Unit"** in systemd vocabulary covers services, slices, targets, sockets, timers, etc. In pctl we only emit **Slice** and **Service** units — when the distinction matters, use the specific noun; use **Unit** only for the union.
- **"Host"** is overloaded: the machine running pctl vs. the allocated `127.0.0.N`. In pctl code and docs, **Host** always means the allocated loopback address; for the machine, use "host system" or "dev host".
- **"Registry"** might suggest an OCI or Nix flake registry. Here it's strictly the per-project state directory under `$XDG_RUNTIME_DIR/pctl/projects/`. Consider renaming later if the term confuses users.
- **"Id"** in code is always **Project id**. No other identifier in the system is called "id", so the short form is safe internally; prefer the full term in user-facing output.
