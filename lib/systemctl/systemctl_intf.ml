(* Systemctl port — shared signature.
 *
 * Both implementations ([Dbus] and [In_mem]) need a Switch at connect
 * time so they can spawn fibers: In_mem for subscriber callbacks, Dbus
 * for the background dispatch fiber that drives sd_bus_process. *)
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
