# `mkProject` spec reference

A project's spec is the record passed to `pctl.lib.${system}.mkProject`. Schema is enforced with `yants`; bad inputs fail at build time with a useful error.

## Top-level

```nix
pctl.lib.${system}.mkProject {
  services = {
    <name> = { ... };   # one entry per service
    ...
  };
}
```

- `services` — attrset; each attribute name becomes part of the unit filename (`pctl-<id>-<name>.service`). Use kebab-case or snake_case; avoid characters systemd rejects in unit names (`.`, `/`, whitespace).

## Per-service fields

| Field           | Type                                              | Required | Notes                                                                                   |
| --------------- | ------------------------------------------------- | -------- | --------------------------------------------------------------------------------------- |
| `command`       | `list<string>`                                    | yes      | argv for `ExecStart`. First element must be an absolute path (e.g. `${pkgs.foo}/bin/foo`). |
| `env`           | `attrs<string>`                                   | no       | Emitted as `Environment=` in the unit.                                                  |
| `dependsOn`     | `list<string>`                                    | no       | Names of other services in the same spec. Produces `Requires=` + `After=` ordering.    |
| `restart`       | `"no" \| "on-failure" \| "always" \| "on-abnormal"` | no     | Shortcut for `Restart=`; equivalent to `serviceConfig.Restart`.                        |
| `limits`        | `{ memoryMax?: string, cpuQuota?: string }`        | no       | `MemoryMax=` and `CPUQuota=`. Strings pass through to systemd (e.g. `"512M"`, `"50%"`). |
| `serviceConfig` | `attrs<string>`                                    | no       | Raw `[Service]` directives — any key systemd accepts.                                   |
| `workspace`    | `{ cwd?: bool, writable?: bool }`                  | no       | First-class access to the project directory. See [Workspace](#workspace).              |
| `readinessProbe`| `{ exec: list<string>, periodSeconds?: int, timeoutSeconds?: int }` | no | Exec probe consulted by `pctl up --wait`. Not rendered into the unit; carried as side-car. |

All strings are passed through verbatim; pctl does not validate values against systemd's accepted vocabulary.

## Sandbox defaults

Every service gets these hardening directives unless explicitly overridden in `serviceConfig`:

```ini
NoNewPrivileges=yes
ProtectControlGroups=yes
ProtectHome=read-only
ProtectKernelModules=yes
ProtectKernelTunables=yes
ProtectSystem=strict
RestrictNamespaces=yes
RestrictSUIDSGID=yes
```

`PrivateTmp=` is **not** default — dev projects often need a shared `/tmp`. Opt in via `serviceConfig.PrivateTmp = "yes"` per service.

Consequence: a service cannot write to `/`, `/home`, or anywhere else outside tmpfs. Declare writable locations via `StateDirectory` / `RuntimeDirectory`:

```nix
pg = {
  command = ["${pgRun}/bin/pctl-pg-run"];
  serviceConfig = {
    StateDirectory = "pctl-@@PROJECT@@-pg";
    RuntimeDirectory = "pctl-@@PROJECT@@-pg";
    RuntimeDirectoryPreserve = "yes";
  };
};
```

These expand to `$XDG_STATE_HOME/pctl-<id>-pg/` and `$XDG_RUNTIME_DIR/pctl-<id>-pg/` respectively.

## Placeholders and environment

Two substitution mechanisms exist — do not confuse them.

### `@@PROJECT@@` — install-time substitution

Any literal `@@PROJECT@@` in a unit's filename or body (including `StateDirectory`, `RuntimeDirectory`, `ExecStart`, etc.) is replaced with the project id at install time, before the unit lands in `$XDG_RUNTIME_DIR/systemd/user.control/`. Use it when you need the id baked into a path systemd resolves *before* exec.

### `$PCTL_HOST` / `$PCTL_ID` — runtime environment

pctl writes a drop-in (`pctl-runtime.conf`) for every service that sets:

- `PCTL_ID=<id>`
- `PCTL_HOST=127.0.0.N` (the allocated loopback address)

These are available to the process at exec time:

- From a shell / the program itself: `$PCTL_HOST`, `$PCTL_ID`.
- From a systemd directive such as `ExecStart=`, use `${PCTL_HOST}` (systemd specifier). Inside a Nix string literal, escape the `$` so the literal string `${PCTL_HOST}` reaches the unit file: `"\${PCTL_HOST}"`.

Not interchangeable with `@@PROJECT@@`: placeholders are literal-substituted at install, env vars are evaluated at service start.

## Workspace

By default every service runs with `ProtectHome=read-only` + `ProtectSystem=strict`, so the process can read the project directory but can't write to it, and its working directory is whatever systemd picks (usually `/`). `workspace` is a typed shortcut for the two adjustments services commonly need:

```nix
web = {
  command = ["${pkgs.buildTool}/bin/build"];
  workspace = {
    cwd = true;       # WorkingDirectory=<project path>
    writable = true;  # bind-mount project dir writable
  };
};
```

| `cwd`  | `writable` | Effect                                                                                                |
| ------ | ---------- | ----------------------------------------------------------------------------------------------------- |
| false  | false      | No change (default).                                                                                  |
| true   | false      | `WorkingDirectory=<path>`. Reads still pass through `ProtectHome=read-only`; writes fail.             |
| false  | true       | `ProtectHome=tmpfs` + `BindPaths=<path>`. Project dir is writable; the rest of `/home` stays hidden.  |
| true   | true       | Combine both — the service starts in the project dir and can write to it.                             |

`writable = true` deliberately keeps `ProtectHome=tmpfs` rather than dropping to `ProtectHome=no`: only the project directory is bind-mounted back in, so sibling projects and the rest of `/home` remain invisible to the service. Your own `serviceConfig` still merges last, so you can override any of these if you need different semantics.

## `readinessProbe`

`readinessProbe.exec` is argv for a command `pctl up --wait` polls until it exits 0. `PCTL_HOST` and `PCTL_ID` are present in its environment, so the probe can reach the same loopback the service is bound to:

```nix
web = {
  command = ["${pkgs.webServer}/bin/server"];
  readinessProbe = {
    exec = ["${pkgs.curl}/bin/curl" "-sf" "--max-time" "1" "http://$PCTL_HOST:8080/healthz"];
    periodSeconds = 1;    # interval between attempts (default 1)
    timeoutSeconds = 30;  # per-probe ceiling (default 30, capped by --timeout)
  };
};
```

The probe is exec-only — use `curl`/`nc`/`pg_isready`/etc. for HTTP/TCP/app-specific checks. It is not rendered into the systemd unit: `mkProject` emits it to a sibling `probes.json` in the store tree, consumed only by the CLI.

## Worked example

The smallest real-world spec with dependencies:

```nix
pctl.lib.${system}.mkProject {
  services = {
    pg = {
      command = ["${pgRun}/bin/pctl-pg-run"];
      restart = "on-failure";
      serviceConfig = {
        Type = "simple";
        StateDirectory = "pctl-@@PROJECT@@-pg";
        RuntimeDirectory = "pctl-@@PROJECT@@-pg";
        RuntimeDirectoryPreserve = "yes";
      };
    };

    migrate = {
      command = ["${migrate}/bin/pctl-pg-migrate"];
      dependsOn = ["pg"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = "yes";
      };
    };

    web = {
      command = ["${web}/bin/pctl-pg-web"];
      dependsOn = ["migrate"];
      restart = "on-failure";
      env = {
        PG_DATABASE = "app";
        PG_USER = "postgres";
      };
    };
  };
}
```

## See also

- [SKILL.md](${CLAUDE_SKILL_DIR}/SKILL.md) — daily usage.
- [SCAFFOLDING.md](${CLAUDE_SKILL_DIR}/SCAFFOLDING.md) — creating a new project.
- [TROUBLESHOOTING.md](${CLAUDE_SKILL_DIR}/TROUBLESHOOTING.md) — what the common errors mean and how to fix them.
