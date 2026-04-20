(* Unit_store port — the frozen interface every adapter must satisfy.
 *
 * One [Unit_filename.t] ↔ one [entry]. The main field carries the rendered
 * .slice or .service bytes; [dropin] carries the companion
 * pctl-runtime.conf bytes (services only — slices never get a drop-in).
 *
 * Adapters:
 *   - [Fs] writes to $XDG_RUNTIME_DIR/systemd/user.control (production).
 *   - [In_mem] is a hashtbl-backed fake (integration tests, phase 2). *)
module type UNIT_STORE = sig
  type t

  type entry = {
    main : string;
    dropin : string option;
  }

  val write : t -> unit_:Schema.Unit_filename.t -> entry -> unit
  val remove : t -> unit_:Schema.Unit_filename.t -> unit
  val list : t -> Schema.Unit_filename.t list
end
