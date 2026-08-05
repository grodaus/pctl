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
 *   - [fail_next_stop]      force the next [stop_unit] to raise
 *   - [fail_next_unit_state], [fail_next_job_pending]
 *                           force the next read of that kind to raise
 *   - [push_state]          directly inject a state (fires subscribers)
 *   - [inspect]             dump (unit, state) pairs
 *   - [ops], [reload_count]
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
  fail_next_stop : (string, string option * string) Hashtbl.t;
      (* unit → (error_name, reply) for the next stop_unit. One-shot: the
         entry is removed on fire so repeated calls don't keep raising.
         The name is what [Bus_errors] classifies on, so a test injecting
         a failure must say which one it is injecting. *)
  fail_next_unit_state : (string, string option * string) Hashtbl.t;
  fail_next_job_pending : (string, string option * string) Hashtbl.t;
      (* unit → (error_name, reply) for the next read of that kind. Same
         one-shot shape as [fail_next_stop], and one table per read rather
         than one shared: the Dbus adapter issues a separate GetUnit +
         Properties.Get pair for each, so a fault hits them independently.
         A shared arm would also be unusable, because [Probe] always reads
         [unit_state] first and would consume it every time. *)
  pending_jobs : (string, unit) Hashtbl.t;
      (* unit → pending start-job marker. Test fixtures toggle this to
         model systemd's behaviour on units with Requires=: StartUnit
         queues a job, leaving the unit Inactive until the dep chain
         clears. Cleared automatically when [start_unit]'s transition
         drops the unit into Active/Failed. *)
  mutable ops_rev : string list;
      (* Recorded BEFORE the call can raise, so an armed failure still
         shows the attempt. Reads are deliberately absent: [Probe] polls
         [unit_state] in a loop, which would bury the jobs and reloads a
         caller's ordering assertion is about. *)
}

let connect ~sw env =
  {
    sw;
    env;
    states = Hashtbl.create 16;
    subscribers = Hashtbl.create 16;
    fail_next = Hashtbl.create 4;
    fail_next_stop = Hashtbl.create 4;
    fail_next_unit_state = Hashtbl.create 4;
    fail_next_job_pending = Hashtbl.create 4;
    pending_jobs = Hashtbl.create 4;
    ops_rev = [];
  }

let record t op = t.ops_rev <- op :: t.ops_rev

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
          (* Report and continue, which is what the Dbus handler does with
           * a raising subscriber (see [Dbus.install_match_rule_and_fiber]).
           * Neither adapter may let it reach the mutator. *)
          try cb state
          with e ->
            prerr_endline
              (Printf.sprintf "pctl: subscriber callback for %s raised: %s" u
                 (Printexc.to_string e))))
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

let do_start t ~unit:u =
  let cur = current_state t u in
  match cur with
  | Active | Activating -> () (* already running / about to be *)
  | Reloading -> () (* treat as no-op, systemd would too *)
  | Inactive | Failed | Deactivating ->
      set_state t u Activating;
      Hashtbl.remove t.pending_jobs u;
      sleep t;
      let terminal =
        if Hashtbl.mem t.fail_next u then (
          Hashtbl.remove t.fail_next u;
          Schema.Failed)
        else Schema.Active
      in
      set_state t u terminal

let do_stop t ~unit:u =
  (match Hashtbl.find_opt t.fail_next_stop u with
   | None -> ()
   | Some (error_name, reply) ->
       Hashtbl.remove t.fail_next_stop u;
       raise
         (Schema.Pctl_error
            (Schema.Unit_op_failed
               { op = "StopUnit"; unit_ = u; error_name; reply })));
  let cur = current_state t u in
  match cur with
  | Inactive | Failed -> ()
  | Deactivating -> ()
  | Active | Activating | Reloading ->
      set_state t u Deactivating;
      sleep t;
      set_state t u Inactive

let start_unit t ~unit:u =
  record t ("start " ^ u);
  do_start t ~unit:u

let stop_unit t ~unit:u =
  record t ("stop " ^ u);
  do_stop t ~unit:u

let restart_unit t ~unit:u =
  (* Stop-then-start sequence, as two fiber-awaited operations: because
   * both [do_stop] and [do_start] sleep between state transitions,
   * subscribers see the full Deactivating → Inactive → Activating →
   * Active sequence. Recorded as one "restart", not as the stop and the
   * start it is built from — Manager.RestartUnit is one call on the
   * wire and callers assert against the wire. *)
  record t ("restart " ^ u);
  do_stop t ~unit:u;
  do_start t ~unit:u

let daemon_reload t = record t "daemon-reload"

(* The In_mem handle holds no external resources; [close] is a no-op.
 * Matches the signature contract used by Pipeline.with_handle. *)
let close _t = ()

(* The in-memory fake doesn't model the `failed` tombstone separately —
 * once a unit transitions back to Inactive it's "cleared" from the
 * real-systemd perspective too. Best-effort no-op matches the Dbus
 * implementation's unknown-unit behaviour. *)
let reset_failed_unit t ~unit:u =
  record t ("reset-failed " ^ u);
  match current_state t u with
  | Schema.Failed -> set_state t u Schema.Inactive
  | _ -> ()

(* Consume an armed read fault. Both reads resolve the unit through
 * GetUnit, so [op] is that method's name and the raised value matches
 * what the Dbus adapter would produce.
 *
 * [absorbed] is what that adapter answers for the ONE name it tolerates
 * (Dbus.get_unit_path_opt, narrowed under pctl-a7p): a no-such-unit reply
 * becomes a value, not an exception. Honouring that here is what stops a
 * test arming that name and passing against propagation production does
 * not do. *)
let consume_read_arm table ~op ~unit:u ~absorbed ~ok =
  match Hashtbl.find_opt table u with
  | None -> ok ()
  | Some (error_name, reply) ->
      Hashtbl.remove table u;
      let e = Schema.Unit_op_failed { op; unit_ = u; error_name; reply } in
      if Bus_errors.is_no_such_unit e then absorbed
      else raise (Schema.Pctl_error e)

let unit_state t ~unit:u =
  consume_read_arm t.fail_next_unit_state ~op:"GetUnit" ~unit:u
    ~absorbed:Schema.Inactive
    ~ok:(fun () -> current_state t u)

let unit_job_pending t ~unit:u =
  consume_read_arm t.fail_next_job_pending ~op:"GetUnit" ~unit:u
    ~absorbed:false
    ~ok:(fun () -> Hashtbl.mem t.pending_jobs u)

let subscribe_unit_changes t ~unit:u cb =
  let r = subscribers_for t u in
  r := cb :: !r

(* ---- test-only APIs -------------------------------------------- *)

let fail_next_start t ~unit:u = Hashtbl.replace t.fail_next u ()

(* [error_name] and [reply] are the two halves of what the Dbus adapter
 * raises: the wire name callers classify on, and the rendered reply. A
 * test that injects one without the other would be pinning a value the
 * real adapter never produces. *)
let fail_next_stop t ~unit:u ~error_name ~reply =
  Hashtbl.replace t.fail_next_stop u (error_name, reply)

(* Arm one read to fail. These exist so a test can drive the caller-side
 * half of pctl-a7p / pctl-q2j: a bus failure reaching either read must
 * reach whoever asked, instead of becoming Inactive or "no job pending".
 * Arming [Bus_errors.no_such_unit] yields the absorbed value instead —
 * see [consume_read_arm]. *)
let fail_next_unit_state t ~unit:u ~error_name ~reply =
  Hashtbl.replace t.fail_next_unit_state u (error_name, reply)

let fail_next_job_pending t ~unit:u ~error_name ~reply =
  Hashtbl.replace t.fail_next_job_pending u (error_name, reply)

let push_state t ~unit:u state = set_state t u state

(* Test-only: mark a unit as having a pending start-job (Inactive +
 * Requires= blocked on a dep). Clears once the unit actually starts
 * transitioning (set by [start_unit]) — callers that want to leave the
 * unit wedged must not invoke [start_unit] between [set_pending_job]
 * and the observation. *)
let set_pending_job t ~unit:u = Hashtbl.replace t.pending_jobs u ()

let clear_pending_job t ~unit:u = Hashtbl.remove t.pending_jobs u

let inspect t =
  Hashtbl.fold (fun u s acc -> (u, s) :: acc) t.states []
  |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* Exists so a caller's *sequence* is assertable and not just its end
 * state: the daemon-reload/start ordering [Lifecycle.apply_plan] depends
 * on leaves no trace in [inspect], and neither does a redundant
 * reload. *)
let ops t = List.rev t.ops_rev

let reload_count t =
  List.length (List.filter (( = ) "daemon-reload") t.ops_rev)

let subscribers_count t ~unit:u =
  match Hashtbl.find_opt t.subscribers u with
  | Some r -> List.length !r
  | None -> 0
