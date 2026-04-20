(* Hot-path bundle: the two paths every [with_project] call needs.
 *
 * Every pctl materializer (up/reload/down/restart/results) starts by
 * resolving a user-supplied directory into:
 *   - the typed [Project_path.t] (already expanded + normalized),
 *   - the [spec.json] file path. Either a `--tree <file>` override, or
 *     the outpath of `nix build <attr>` — which, because mkProject is
 *     a [pkgs.writeText] derivation, IS the spec.json file directly.
 *
 * Bundling them here lets the pipeline pass a single value around
 * instead of loose strings. The record is [private] so callers can
 * only obtain a [t] through [resolve]. *)

type t = private {
  project : Schema.project_path;
  spec_file : Fpath.t;
}

module type NIX = Nix_build.S
(** Alias for [Nix_build.S] — both [Project_paths] and [Pipeline] live
    in the [cli] library and already depend on [Nix_build], so the
    aliases keep the three signatures in lock-step with one source. *)

val resolve :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  nix:(module NIX) ->
  ?tree:string ->
  ?nix_attr:string ->
  Schema.project_path ->
  t
(** Resolve the bundle.

    - [tree] = user-supplied spec.json override (`pctl up --tree <file>`):
      when present and non-empty, parsed via [Fpath.v] and asserted absolute.
    - Otherwise, build `<nix_attr>` (defaulting to `.#pctl`) via
      [Nix.out_path] with [cwd] set to [project]; the outpath itself is
      the spec.json file (writeText semantics).

    Raises [Schema.Pctl_error (Identity_invalid …)] if the resolved
    [spec_file] does not parse as an absolute path. *)
