# Ubiquitous Language

## Project lifecycle

| Term              | Definition                                                                                                   | Aliases to avoid        |
| ----------------- | ------------------------------------------------------------------------------------------------------------ | ----------------------- |
| **Project**       | A directory whose flake declares a set of services via `pctl.lib.${system}.mkProject`                        | App, workspace          |
| **Project path**  | Absolute path on disk of a project; the sole input to identity derivation                                    | Cwd, dir                |
| **Spec**          | The declarative Nix expression passed to `mkProject` — a record of named service definitions                 | Config, declaration     |
| **Service**       | A single long-running process declared by the spec (`command`, `env`, `dependsOn`, `limits`, `serviceConfig`)| Process, daemon         |
| **Up**            | Installing units, starting the slice, and starting every service in the project                              | Start, launch           |
| **Reload**        | Recomputing the spec, diffing against the stored manifest, and minimally restarting changed services         | Restart, rebuild        |
| **Down**          | Stopping the slice, removing installed units, dropping the registry entry                                    | Stop, teardown          |

## Artifacts

| Term            | Definition                                                                                                                  | Aliases to avoid             |
| --------------- | --------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| **Unit**        | A systemd unit file — either a **slice** or a **service** — emitted by pctl                                                 | File, config                 |
| **Slice**       | The `pctl-<id>.slice` that cgroup-parents every service in a project                                                        | Group, namespace             |
| **Store tree**  | The `/nix/store` output of `mkProject` — placeholder-bearing unit files on disk, consumed by `up` and `reload`              | Tree, bundle, output         |
| **Drop-in**     | The `pctl-runtime.conf` file pctl writes into `<unit>.d/` carrying **PCTL_ID** (+ **PCTL_HOST** on services)                | Override, extension          |
| **Manifest**    | `{ unit-filename: sha256 }` snapshot persisted on `up`/`reload`, used as the left side of the next reload diff              | Hash map, lock file          |
| **User.control**| `$XDG_RUNTIME_DIR/systemd/user.control/` — the live unit directory systemd --user reads                                     | Install dir, runtime dir     |

## Identity & allocation

| Term             | Definition                                                                                                     | Aliases to avoid       |
| ---------------- | -------------------------------------------------------------------------------------------------------------- | ---------------------- |
| **Project id**   | `<sanitized_basename>_<hash8>` deterministically derived from **project path**; appears in every unit name     | Name, slug             |
| **Host**         | A `127.0.0.N` address allocated per project so concurrent projects never race on ports                         | IP, address            |
| **Registry**     | Per-project state at `$XDG_RUNTIME_DIR/pctl/projects/<id>/`: `path`, `host`, `manifest.nuon`, `started_at`     | Store, database        |
| **PCTL_ID**      | Env var set in every drop-in exposing the **project id** to the service process                                | —                      |
| **PCTL_HOST**    | Env var set in service drop-ins exposing the allocated **host** to the service process                         | —                      |
| **@@PROJECT@@**  | Placeholder token in filenames and unit bodies inside the **store tree**, substituted at install time          | Template, marker       |
| **Worktree**     | A distinct project path (e.g. a git worktree) whose identity-from-path rule guarantees a distinct **project id**, **slice**, and **host** — letting siblings coexist | Copy, clone |

## Reload diff

| Term                     | Definition                                                          | Aliases to avoid |
| ------------------------ | ------------------------------------------------------------------- | ---------------- |
| **Plan**                 | The ordered table of `{unit, action, old_hash, new_hash}` rows a diff produces | Diff, changeset  |
| **Action: added (+)**    | Unit present in new **manifest**, absent in old — `start`           | New              |
| **Action: changed (~)**  | Unit in both manifests, hashes differ — `restart`                   | Updated          |
| **Action: unchanged (=)**| Unit in both manifests, hashes equal — no-op                        | Same             |
| **Action: removed (-)**  | Unit absent in new, present in old — `stop` and delete              | Gone, deleted    |

## Testing

| Term            | Definition                                                                                                             | Aliases to avoid   |
| --------------- | ---------------------------------------------------------------------------------------------------------------------- | ------------------ |
| **Reality test**| An e2e test run against the host's real `systemd --user`; the only layer that verifies actual activation behaviour     | Smoke test         |
| **Harness**     | Shared setup/teardown helpers (`setup`, `teardown`, `write-tree`, `wait-active`, `cleanup-stragglers`)                 | Fixture, helpers   |
| **Scratch**     | The ephemeral record `{tmp, project_dir, tree_dir}` a harness produces for one test                                    | Sandbox, workspace |
| **Straggler**   | A slice left behind on the host session by a crashed test run; swept at suite start by id                              | Leak, zombie       |

## Relationships

- A **Project** has exactly one **Project id** (pure function of **Project path**) and exactly one allocated **Host**.
- A **Project** owns one **Slice** and zero-or-more **Service** units; every **Service** runs inside its **Project**'s **Slice**.
- `mkProject` produces one **Store tree** per **Spec**; `up` and `reload` both consume a **Store tree**.
- Each installed **Unit** has exactly one **Drop-in** carrying runtime env (**PCTL_ID** on all, **PCTL_HOST** on services only).
- `up` writes one **Registry** entry and one **Manifest**; `reload` reads the **Manifest**, computes a **Plan**, then rewrites both.
- Two **Worktrees** of the same repo have distinct **Project ids** and **Hosts** and therefore distinct **Slices** that coexist on one `systemd --user` session.

## Example dialogue

> **Dev:** "When I run `pctl up`, where does the **store tree** actually come from?"

> **Domain expert:** "`mkProject` reads your **spec** and emits a **store tree** with `@@PROJECT@@` placeholders in every filename and body. `up` resolves the **project id** from the **project path**, substitutes the placeholder at install time, and writes the resulting **units** into **user.control** along with a **drop-in** per unit carrying **PCTL_ID** and (for services) **PCTL_HOST**."

> **Dev:** "So the **slice** only gets **PCTL_ID**, not **PCTL_HOST**?"

> **Domain expert:** "Right — the **host** is a port-isolation tool for service processes. The **slice** is a cgroup parent, it doesn't bind anything. Only the **service** drop-ins carry **PCTL_HOST**."

> **Dev:** "And **reload** — what changes when I edit one service's command?"

> **Domain expert:** "The new **store tree** produces a new **manifest**. Diffing against the stored **manifest** yields a **plan**: the changed service gets a `~` action, everything else `=`. `reload` runs `systemctl restart` on the `~` units only — the **slice** never bounces."

> **Dev:** "What if I have two **worktrees** of the same repo checked out?"

> **Domain expert:** "Each has a distinct **project path**, so each gets a distinct **project id**, **host**, **slice**, and **registry** entry. They share the `systemd --user` session but never collide — that's the whole point of hashing the path into the **project id**."

## Flagged ambiguities

- **"Tree"** in conversation sometimes means "store tree" and sometimes the abstract set of rendered units at any pipeline stage. Canonical term is **Store tree** when referring to the on-disk `/nix/store` output; avoid bare "tree" in code comments and docs.
- **"Unit"** in systemd vocabulary covers services, slices, targets, sockets, timers, etc. In pctl we only emit **Slice** and **Service** units — when the distinction matters, use the specific noun; use **Unit** only for the union.
- **"Host"** is overloaded: the machine running pctl vs. the allocated `127.0.0.N`. In pctl code and docs, **Host** always means the allocated loopback address; for the machine, use "host system" or "dev host".
- **"Registry"** might suggest an OCI or Nix flake registry. Here it's strictly the per-project state directory under `$XDG_RUNTIME_DIR/pctl/projects/`. Consider renaming later if the term confuses users.
- **"Id"** in code is always **Project id**. No other identifier in the system is called "id", so the short form is safe internally; prefer the full term in user-facing output.
