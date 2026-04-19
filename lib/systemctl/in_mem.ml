(* In_mem — pure Eio-aware fake Systemctl.
 *
 * Hashtbl keyed on unit name. Mutators transition through the natural
 * systemd state machine (Inactive|Failed → Activating → Active,
 * Active|… → Deactivating → Inactive) with a tiny `Eio.Time.sleep`
 * between transitions so subscribers observe every intermediate state.
 *
 * Subscriber callbacks fire via [Eio.Fiber.fork] so a slow (or hung)
 * callback can't deadlock the mutator. Forks attach to the switch
 * captured at [connect] time.
 *
 * Test-only APIs are exposed alongside the SYSTEMCTL surface:
 *   - [fail_next_start]     force the next [start_unit] to end in Failed
 *   - [push_state]          directly inject a state (fires subscribers)
 *   - [inspect]             dump (unit, state) pairs
 *   - [subscribers_count]   leak check
 *)

(* Tiny sleep between transitions — large enough that subscribers,
 * running as forked fibers on a separate ready queue, can observe
 * each intermediate state before the mutator pushes the next one. *)
let transition_sleep_s = 0.001

type subscriber = Schema.state -> unit

type t = {
  sw : Eio.Switch.t;
  env : Eio_unix.Stdenv.base;
  states : (string, Schema.state) Hashtbl.t;
  subscribers : (string, subscriber list ref) Hashtbl.t;
  fail_next : (string, unit) Hashtbl.t;
}

let connect ~sw env =
  {
    sw;
    env;
    states = Hashtbl.create 16;
    subscribers = Hashtbl.create 16;
    fail_next = Hashtbl.create 4;
  }

let subscribers_for t u =
  match Hashtbl.find_opt t.subscribers u with
  | Some r -> r
  | None ->
      let r = ref [] in
      Hashtbl.add t.subscribers u r;
      r

(* Notify all subscribers of the new state. Each callback is spawned in
 * its own fiber so misbehaving callbacks don't block the mutator nor
 * each other. *)
let notify t u state =
  let r = subscribers_for t u in
  List.iter
    (fun cb ->
      Eio.Fiber.fork ~sw:t.sw (fun () ->
          try cb state
          with _ ->
            (* Tests don't want subscriber exceptions to crash the
             * suite. In production the only caller is [Probe], which
             * must propagate — but production uses the Dbus impl, so
             * swallow here. *)
            ()))
    !r

let set_state t u state =
  Hashtbl.replace t.states u state;
  notify t u state

let sleep t =
  Eio.Time.sleep (t.env#clock :> float Eio.Time.clock_ty Eio.Std.r)
    transition_sleep_s

let current_state t u =
  match Hashtbl.find_opt t.states u with
  | Some s -> s
  | None -> Schema.Inactive

let start_unit t ~unit:u =
  let cur = current_state t u in
  match cur with
  | Active | Activating -> () (* already running / about to be *)
  | Reloading -> () (* treat as no-op, systemd would too *)
  | Inactive | Failed | Deactivating ->
      set_state t u Activating;
      sleep t;
      let terminal =
        if Hashtbl.mem t.fail_next u then (
          Hashtbl.remove t.fail_next u;
          Schema.Failed)
        else Schema.Active
      in
      set_state t u terminal

let stop_unit t ~unit:u =
  let cur = current_state t u in
  match cur with
  | Inactive | Failed -> ()
  | Deactivating -> ()
  | Active | Activating | Reloading ->
      set_state t u Deactivating;
      sleep t;
      set_state t u Inactive

let restart_unit t ~unit:u =
  (* Stop-then-start sequence, as two fiber-awaited operations: because
   * both [stop_unit] and [start_unit] sleep between state transitions,
   * subscribers see the full Deactivating → Inactive → Activating →
   * Active sequence. *)
  stop_unit t ~unit:u;
  start_unit t ~unit:u

let daemon_reload _t = ()

let unit_state t ~unit:u = current_state t u

let subscribe_unit_changes t ~unit:u cb =
  let r = subscribers_for t u in
  r := cb :: !r

(* ---- test-only APIs -------------------------------------------- *)

let fail_next_start t ~unit:u = Hashtbl.replace t.fail_next u ()

let push_state t ~unit:u state = set_state t u state

let inspect t =
  Hashtbl.fold (fun u s acc -> (u, s) :: acc) t.states []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

let subscribers_count t ~unit:u =
  match Hashtbl.find_opt t.subscribers u with
  | Some r -> List.length !r
  | None -> 0
