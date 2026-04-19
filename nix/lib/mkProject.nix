# mkProject — Nix -> spec.json emitter (Q11 / plan "Public contracts").
#
# This is the Nix half of the Nix <-> OCaml contract. It takes the same
# user-written `{ services = { ... }; }` shape the Nushell PoC accepted
# (frozen; tuor's flake.nix call site changes zero lines), validates it
# with yants, merges sandbox defaults into each service's `service_config`,
# and emits a single spec.json via `pkgs.writeText`.
#
# The OCaml CLI reads this spec.json at `up` / `reload` time, derives
# concrete unit filenames from the project id, renders unit bytes, and
# writes them into user.control. Nix never renders unit files — that
# responsibility lives in `lib/render/` on the OCaml side.
#
# v2 schema: no `@@PROJECT@@` / `@@PROJECT_PATH@@` placeholders. The spec
# is pure logical data. Workspace-derived keys (WorkingDirectory,
# BindPaths, ProtectHome) are produced by the OCaml renderer from
# `workspace.cwd` / `workspace.writable`; the Nix side emits only the
# workspace flags.
#
# Return value: the `pkgs.writeText` derivation itself. Its outPath IS the
# spec.json file (writeText semantics). Consumers like tuor write
# `packages.pctl = mkProject { ... }` and then `nix build .#pctl`
# produces `./result` pointing directly at the file.
#
# See "## Public-contract breaks" (Phase 0) at the bottom of
# docs/src/plans/20260419-ocaml-rewrite.md for the reasoning on why this
# returns a derivation directly rather than an attrset with a `spec` field.
{
  pkgs,
  types,
}: {services}: let
  inherit (pkgs) lib;

  sandboxDefaults = import ./sandbox-defaults.nix;

  # Yants validation — fails early with a clear error when a service's
  # shape drifts from types.nix.
  validated = lib.mapAttrs (_: s: types.service s) services;

  serviceNames = builtins.attrNames validated;

  checkDeps = svcName: svc: let
    deps = svc.dependsOn or [];
    missing = builtins.filter (d: !(builtins.elem d serviceNames)) deps;
  in
    if missing == []
    then null
    else throw "pctl.mkProject: service '${svcName}' dependsOn references unknown service(s): ${lib.concatStringsSep ", " missing}";

  _ = lib.mapAttrsToList checkDeps validated;
  depsChecked = builtins.deepSeq _ validated;

  # Inferred `kind` (Type= in systemd parlance) is derived from the
  # user's explicit serviceConfig.Type if present, else defaults to
  # "simple".
  inferKind = svc: let
    explicit = (svc.serviceConfig or {}).Type or null;
  in
    if explicit != null
    then explicit
    else "simple";

  # Merge sandbox defaults + command/env/limits + user's explicit
  # serviceConfig (last writer wins). Produces the final string-keyed
  # map OCaml consumes as-is. Workspace-derived keys are NOT included
  # here — OCaml renders them from `workspace` at install time.
  buildServiceConfig = svc: let
    envAttrs = svc.env or {};
    envLines = lib.mapAttrsToList (k: v: "${k}=${v}") envAttrs;
    # systemd accepts a single Environment= with multiple K=V pairs
    # space-separated; join here so service_config stays flat
    # (string -> string) without needing list-valued entries.
    envJoined = lib.concatStringsSep " " envLines;

    limits = svc.limits or {};

    base =
      sandboxDefaults
      // {
        ExecStart = lib.concatStringsSep " " svc.command;
      }
      // lib.optionalAttrs (envLines != []) {Environment = envJoined;}
      // lib.optionalAttrs (svc ? restart) {Restart = svc.restart;}
      // lib.optionalAttrs (limits ? memoryMax) {MemoryMax = limits.memoryMax;}
      // lib.optionalAttrs (limits ? cpuQuota) {CPUQuota = limits.cpuQuota;}
      // (svc.serviceConfig or {});

    # Always force Type= — even if the user didn't set one — so OCaml's
    # `kind` derivation from spec.json is unambiguous.
    withType = base // {Type = inferKind svc;};
  in
    lib.mapAttrs (_: toString) withType;

  buildProbe = svc:
    if svc ? readinessProbe
    then {
      inherit (svc.readinessProbe) exec;
      period_seconds = svc.readinessProbe.periodSeconds or 1;
      timeout_seconds = svc.readinessProbe.timeoutSeconds or 30;
    }
    else null;

  buildService = _svcName: svc: {
    kind = inferKind svc;
    depends_on = svc.dependsOn or [];
    workspace = {
      cwd = (svc.workspace or {}).cwd or false;
      writable = (svc.workspace or {}).writable or false;
    };
    probe = buildProbe svc;
    service_config = buildServiceConfig svc;
  };

  servicesObj = lib.mapAttrs buildService depsChecked;

  spec = {
    version = 2;
    slice = {
      # Slice-level config stays minimal today; sandbox hardening is
      # per-service. Plan schema v2 section of the rewrite doc defines
      # the shape.
      slice_config = {};
    };
    services = servicesObj;
  };
in
  # Return the writeText derivation directly so `nix build .#pctl`
  # produces `./result -> <store path>/pctl-spec.json`. The outPath IS
  # the file (writeText semantics). Tuor uses this as
  # `packages.pctl = mkProject { ... };` — it must be a derivation, not
  # a plain attrset, for `nix build .#pctl` to resolve. See the
  # "## Public-contract breaks" note at the bottom of the rewrite plan.
  pkgs.writeText "pctl-spec.json" (builtins.toJSON spec)
