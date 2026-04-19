(* Systemctl port — shared signature.
 *
 * Plan binding: docs/src/plans/20260419-ocaml-rewrite.md §"Systemctl port".
 *
 * Note: the plan's verbatim signature has
 *   val connect : Eio_unix.Stdenv.base -> t
 * Implementations need a Switch they can borrow to spawn fibers (both
 * for In_mem subscriber callbacks and for the Dbus background dispatch
 * fiber). We widen the signature to take a switch at connect time.
 * This is a deliberate deviation from the plan's verbatim signature,
 * flagged in the Phase 3 report. *)
module type SYSTEMCTL = sig
  type t

  val connect : sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> t
  val start_unit : t -> unit:string -> unit
  val stop_unit : t -> unit:string -> unit
  val restart_unit : t -> unit:string -> unit
  val daemon_reload : t -> unit
  val unit_state : t -> unit:string -> Schema.state

  val subscribe_unit_changes :
    t -> unit:string -> (Schema.state -> unit) -> unit
end
