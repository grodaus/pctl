(* Pipeline — the common-case materializer for pctl commands.
 *
 * Invariants enforced structurally (callers cannot reorder):
 *   1. Session.reset before opportunistic_sweep (else sweep sees stale
 *      runtime columns).
 *   2. opportunistic_sweep before host allocation (else orphan units
 *      occupy a host we're about to allocate).
 *   3. Install.write_units before State.Projects.replace_manifest
 *      (manifest row hashes must match the bytes on disk).
 *   4. replace_manifest before Plan.apply (the diff must reflect the
 *      persisted state, not the in-flight state).
 *   5. Systemctl handle created fresh per Plan/Probe/Gc invocation,
 *      scoped to an inner Eio.Switch so the dispatch fiber drains
 *      before the outer switch releases.
 *   6. Pctl_error raised internally, caught once by [run] — which
 *      maps it to an exit bucket and renders the error on stderr.
 *
 * Ports & Adapters on the three cross-process edges that hurt the
 * integration story today: Systemctl (Dbus | In_mem), Nix_build
 * (Real | test stub), Clock (Real | Frozen). State.Db, Install, Spec
 * remain in-process — they have no second implementation awaiting. *)

module type NIX = sig
  val out_path :
    attr:string ->
    path:string ->
    env:Eio_unix.Stdenv.base ->
    sw:Eio.Switch.t ->
    string

  val read_spec_blob : string -> string option
end

module type CLOCK = Clock.S

module type PORTS = sig
  module Systemctl : Systemctl.S
  module Nix : NIX
  module Clock : CLOCK
end

val run : (unit -> unit) -> int
(** Invariant 6. Runs [f ()]; catches [Schema.Pctl_error] (prints the
    rendered message, returns the matching exit bucket). Any other
    exception is logged generically and returns 1. *)

val resolve_path : string option -> Schema.project_path
(** Expand [None]/empty to [Sys.getcwd ()]; expand [Some p] via
    [Schema.Project_path.of_raw] (tilde + env var substitution,
    normalization). *)

val with_connection :
  env:Eio_unix.Stdenv.base ->
  sw:Eio.Switch.t ->
  (State.Db.t -> 'a) ->
  'a
(** Open the registry DB, run migrations, run [Session.reset], then
    invoke [f]. The connection closes when the switch releases. *)

module Make (P : PORTS) : sig
  (** Commands that share the invariant chain 1–5. Production wiring
      lives in [Prod]; tests wire their own [PORTS]. *)

  val purge :
    env:Eio_unix.Stdenv.base -> conn:State.Db.t -> int
  (** Drop every non-Live project row + its unit files. Exposed so
      [gc_cmd] can trigger a purge without owning its own Systemctl
      handle. *)

  val up :
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    ?tree:string ->
    ?nix:string ->
    ?path:string ->
    ?no_block:bool ->
    ?wait:bool ->
    ?timeout:int ->
    unit ->
    int

  val reload :
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    ?tree:string ->
    ?nix:string ->
    ?path:string ->
    unit ->
    int

  val down :
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    ?path:string ->
    ?quiet:bool ->
    unit ->
    int

  val restart :
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    svc:string ->
    ?path:string ->
    unit ->
    int

  val results :
    sw:Eio.Switch.t ->
    env:Eio_unix.Stdenv.base ->
    ?path:string ->
    ?timeout:int ->
    ?json:bool ->
    unit ->
    int
end

module Prod : module type of Make (struct
  module Systemctl = Systemctl.Dbus
  module Nix = Nix_build.Real
  module Clock = Clock.Real
end)
(** Production wiring — what [bin/pctl.ml] and the e2e harness use. *)
