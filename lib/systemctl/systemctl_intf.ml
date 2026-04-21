(* Systemctl port — shared signature.
 *
 * Both implementations ([Dbus] and [In_mem]) need a Switch at connect
 * time so they can spawn fibers: In_mem for subscriber callbacks, Dbus
 * for the background dispatch fiber that drives sd_bus_process. *)
module type SYSTEMCTL = sig
  type t

  val connect : sw:Eio.Switch.t -> Eio_unix.Stdenv.base -> t

  (* Best-effort release of the handle. Idempotent; safe to call even
   * after the owning switch has released. Pipeline wraps every
   * [connect] in [Fun.protect ~finally:close] so the Dbus dispatch
   * fiber drains before the outer switch tears down. *)
  val close : t -> unit

  val start_unit : t -> unit:string -> unit
  val stop_unit : t -> unit:string -> unit
  val restart_unit : t -> unit:string -> unit
  val daemon_reload : t -> unit
  val unit_state : t -> unit:string -> Schema.state

  (* True iff systemd currently has a pending Job for this unit — i.e.
   * the unit's `Job` property on `org.freedesktop.systemd1.Unit`
   * points at an active job path (non-"/"). Used by [Probe] to tell
   * "queued, not yet started" (Inactive + job) from "terminally
   * Inactive" (Inactive + no job). An unknown/unloaded unit has no
   * pending job. *)
  val unit_job_pending : t -> unit:string -> bool

  (* Best-effort: clear the `failed` tombstone systemd holds after a
   * service exited non-zero. Matches `systemctl --user reset-failed`.
   * Unknown unit names and already-cleared units do not raise. *)
  val reset_failed_unit : t -> unit:string -> unit

  val subscribe_unit_changes :
    t -> unit:string -> (Schema.state -> unit) -> unit
end
