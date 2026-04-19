# pctl

Declarative Nix spec → `systemd --user` unit materializer. Each project gets its own slice, a dedicated `127.0.0.N` host, and a session-scoped manifest — so concurrent projects and git worktrees never race on ports or unit names.

## What it does

Your flake declares services via `pctl.lib.${system}.mkProject { services = { ... }; }`. `pctl` turns that into `.service` + `.slice` unit files under `$XDG_RUNTIME_DIR/systemd/user.control/`, starts them inside a per-project slice, and waits on readiness probes in parallel. Reloads diff the manifest against the previous one and minimally restart only the units whose hash changed (`+`/`~`/`=`/`-`).

## Build

```
nix build
./result/bin/pctl --help
```

Or run without building:

```
nix run . -- --help
```

## Commands

`pctl {up,reload,down,restart,results,host,logs,status,list,init,gc}` — see `pctl --help` for full argv.

## Workflow at a glance

```
nix run . -- init       # scaffold a flake in a new project
nix run . -- up          # build spec, install units, start services
nix run . -- reload      # recompute, diff, minimally restart
nix run . -- down        # stop slice, remove units
```

## Docs

- [UBIQUITOUS_LANGUAGE.md](./UBIQUITOUS_LANGUAGE.md) — every domain term. Read this first.
- [CLAUDE.md](./CLAUDE.md) — project conventions for contributors and agents.
- [docs/src/plans/20260419-ocaml-rewrite.md](./docs/src/plans/20260419-ocaml-rewrite.md) — the architecture plan (OCaml rewrite, decisions Q1–Q14).

## License

MIT — see [LICENSE](./LICENSE).
