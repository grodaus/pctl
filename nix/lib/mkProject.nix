# mkProject — Nix -> spec.json emitter (Q11 / plan "Public contracts").
#
# This is the Nix half of the Nix <-> OCaml contract. It takes the same
# user-written `{ services = { ... }; }` shape the Nushell PoC accepted
# (frozen; tuor's flake.nix call site changes zero lines), validates it
# with yants, merges sandbox defaults into each service's `service_config`,
# and emits a single spec.json via `pkgs.writeText`.
#
# The OCaml CLI reads this spec.json at `up` / `reload` time, substitutes
# @@PROJECT@@ / @@PROJECT_PATH@@ at install time, renders unit bytes, and
# writes them into user.control. Nix never renders unit files any more —
# that responsibility moved into `lib/render/` on the OCaml side.
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

  placeholder = "@@PROJECT@@";

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
  # "simple" — matches the behaviour in render.nix that OCaml is
  # replacing. Plan schema v1 lists the accepted values.
  inferKind = svc: let
    explicit = (svc.serviceConfig or {}).Type or null;
  in
    if explicit != null
    then explicit
    else "simple";

  # Build the workspace-derived service_config fragment (BindPaths,
  # ProtectHome, WorkingDirectory). Keeps @@PROJECT_PATH@@ placeholder
  # intact — OCaml substitutes at install time.
  workspaceConfig = svc: let
    ws = svc.workspace or {};
    cwd = ws.cwd or false;
    writable = ws.writable or false;
  in
    lib.optionalAttrs cwd {
      WorkingDirectory = "@@PROJECT_PATH@@";
    }
    // lib.optionalAttrs writable {
      ProtectHome = "tmpfs";
      # BindPaths is list-valued in systemd; stringify as a single
      # space-separated string so OCaml's service_config:
      # `(string * string) list` consumer sees a plain scalar. OCaml's
      # renderer expands this back to one line per path at ini-write time.
      BindPaths = "@@PROJECT_PATH@@";
    };

  # Merge sandbox defaults + command/env/limits + workspace + user's
  # explicit serviceConfig (last writer wins). Produces the final
  # string-keyed map OCaml consumes as-is — no further merging on the
  # OCaml side. All values coerced to strings so the JSON shape is
  # `{ "K": "V" }` everywhere (OCaml reads as (string * string) list,
  # plan "Internal schema").
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
      // (workspaceConfig svc)
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

  buildService = svcName: svc: {
    kind = inferKind svc;
    depends_on = svc.dependsOn or [];
    workspace = {
      cwd = (svc.workspace or {}).cwd or false;
      writable = (svc.workspace or {}).writable or false;
    };
    probe = buildProbe svc;
    unit_filename = "pctl-${placeholder}-${svcName}.service";
    service_config = buildServiceConfig svc;
  };

  servicesObj = lib.mapAttrs buildService depsChecked;

  spec = {
    version = 1;
    slice = {
      unit_filename = "pctl-${placeholder}.slice";
      # Slice-level config stays minimal today; sandbox hardening is
      # per-service. Plan schema v1 section of the rewrite doc defines
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
