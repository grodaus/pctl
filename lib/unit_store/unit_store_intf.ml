(* Unit_store port — the frozen interface every adapter must satisfy.
 *
 * One [Unit_filename.t] ↔ one [entry]. The main field carries the rendered
 * .slice or .service bytes; [dropin] carries the companion
 * pctl-runtime.conf bytes (services only — slices never get a drop-in).
 *
 * [entry] lives at the top level, not inside [UNIT_STORE], so every
 * adapter and every caller (Lifecycle, tests) refers to the same
 * nominal record. Keeping the record inside the signature would create
 * a fresh type per adapter — structurally identical, nominally
 * distinct — and functor callers would then have to wrap a fresh
 * record per adapter.
 *
 * Adapters:
 *   - [Fs] writes to $XDG_RUNTIME_DIR/systemd/user.control (production).
 *   - [In_mem] is a hashtbl-backed fake (integration tests, phase 2). *)

type entry = {
  main : string;
  dropin : string option;
}

module type UNIT_STORE = sig
  type t

  val write : t -> unit_:Schema.Unit_filename.t -> entry -> unit

  (* [None] iff the main unit file is absent. [read (write e) = Some e]. *)
  val read : t -> unit_:Schema.Unit_filename.t -> entry option

  val remove : t -> unit_:Schema.Unit_filename.t -> unit
  val list : t -> Schema.Unit_filename.t list
end
