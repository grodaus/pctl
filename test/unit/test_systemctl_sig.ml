(* Phase 3 unit suite — property-style tests over [Systemctl.In_mem].
 *
 * Every test drives Eio via a local [eio_run] helper (same pattern as
 * test/integration/test_state.ml). Subscribers fire on forked fibers,
 * so we collect their observations into a mutable list protected by
 * the single-domain OCaml default runtime — no locks needed.
 *
 * Subscribers see states out of order only if the mutator's sleep is
 * shorter than fiber scheduling grants; we use an explicit small
 * sleep after each mutator call to let the fork backlog drain.
 *)

module In_mem = Systemctl.In_mem

let state_testable =
  Alcotest.testable
    (fun fmt s -> Format.pp_print_string fmt (Schema.state_to_string s))
    ( = )

let states_testable = Alcotest.list state_testable

(* Lets subscriber-fork callbacks run. The mutator sleeps 1 ms between
 * transitions; a 5 ms drain after the call is generous. *)
let drain t =
  Eio.Time.sleep (t#clock :> float Eio.Time.clock_ty Eio.Std.r) 0.005

let eio_run (f : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> unit) : unit =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw -> f ~sw ~env

let collect_subscriber () =
  let observed = ref [] in
  let cb s = observed := s :: !observed in
  observed, cb

let test_start_transitions () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  let obs, cb = collect_subscriber () in
  In_mem.subscribe_unit_changes sc ~unit:"a.service" cb;
  In_mem.start_unit sc ~unit:"a.service";
  drain env;
  Alcotest.check states_testable
    "Activating then Active observed"
    [ Schema.Activating; Schema.Active ]
    (List.rev !obs);
  Alcotest.check state_testable "final state"
    Schema.Active
    (In_mem.unit_state sc ~unit:"a.service")

let test_stop_transitions () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  In_mem.push_state sc ~unit:"a.service" Schema.Active;
  let obs, cb = collect_subscriber () in
  In_mem.subscribe_unit_changes sc ~unit:"a.service" cb;
  In_mem.stop_unit sc ~unit:"a.service";
  drain env;
  Alcotest.check states_testable
    "Deactivating then Inactive observed"
    [ Schema.Deactivating; Schema.Inactive ]
    (List.rev !obs);
  Alcotest.check state_testable "final state"
    Schema.Inactive
    (In_mem.unit_state sc ~unit:"a.service")

let test_unit_state_unknown () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  Alcotest.check state_testable "unknown unit → Inactive"
    Schema.Inactive
    (In_mem.unit_state sc ~unit:"nope.service")

let test_fail_next_start () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  In_mem.fail_next_start sc ~unit:"a.service";
  let obs, cb = collect_subscriber () in
  In_mem.subscribe_unit_changes sc ~unit:"a.service" cb;
  In_mem.start_unit sc ~unit:"a.service";
  drain env;
  Alcotest.check states_testable
    "Activating then Failed observed"
    [ Schema.Activating; Schema.Failed ]
    (List.rev !obs);
  Alcotest.check state_testable "final state = Failed"
    Schema.Failed
    (In_mem.unit_state sc ~unit:"a.service");
  (* fail_next_start is one-shot — a subsequent start_unit should
   * succeed. Reset state so start_unit moves again. *)
  In_mem.push_state sc ~unit:"a.service" Schema.Inactive;
  In_mem.start_unit sc ~unit:"a.service";
  drain env;
  Alcotest.check state_testable "second start: Active"
    Schema.Active
    (In_mem.unit_state sc ~unit:"a.service")

let test_restart_transitions () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  In_mem.push_state sc ~unit:"a.service" Schema.Active;
  let obs, cb = collect_subscriber () in
  In_mem.subscribe_unit_changes sc ~unit:"a.service" cb;
  (* subscription is attached AFTER push_state, so the initial Active
   * fires once; consume it. *)
  drain env;
  obs := [];
  In_mem.restart_unit sc ~unit:"a.service";
  drain env;
  Alcotest.check states_testable
    "restart: Deactivating, Inactive, Activating, Active"
    [
      Schema.Deactivating;
      Schema.Inactive;
      Schema.Activating;
      Schema.Active;
    ]
    (List.rev !obs)

let test_daemon_reload_noop () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  In_mem.push_state sc ~unit:"a.service" Schema.Active;
  In_mem.push_state sc ~unit:"b.service" Schema.Inactive;
  let before = In_mem.inspect sc in
  In_mem.daemon_reload sc;
  let after = In_mem.inspect sc in
  Alcotest.(check (list (pair string state_testable)))
    "daemon_reload does not mutate state" before after

let test_push_state_notifies () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  let obs, cb = collect_subscriber () in
  In_mem.subscribe_unit_changes sc ~unit:"a.service" cb;
  In_mem.push_state sc ~unit:"a.service" Schema.Reloading;
  drain env;
  Alcotest.check states_testable
    "push_state fires subscriber"
    [ Schema.Reloading ]
    (List.rev !obs)

let test_subscribers_count () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  Alcotest.(check int)
    "zero before subscribe" 0
    (In_mem.subscribers_count sc ~unit:"a.service");
  let _, cb = collect_subscriber () in
  In_mem.subscribe_unit_changes sc ~unit:"a.service" cb;
  In_mem.subscribe_unit_changes sc ~unit:"a.service" cb;
  Alcotest.(check int)
    "two after subscribe" 2
    (In_mem.subscribers_count sc ~unit:"a.service")

let test_inspect_sorted () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  In_mem.push_state sc ~unit:"b.service" Schema.Inactive;
  In_mem.push_state sc ~unit:"a.service" Schema.Active;
  let names = List.map fst (In_mem.inspect sc) in
  Alcotest.(check (list string))
    "inspect sorted by unit name" [ "a.service"; "b.service" ] names

let test_idempotent_start () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  In_mem.start_unit sc ~unit:"a.service";
  drain env;
  let obs, cb = collect_subscriber () in
  In_mem.subscribe_unit_changes sc ~unit:"a.service" cb;
  (* already Active; a second start_unit should be a no-op. *)
  In_mem.start_unit sc ~unit:"a.service";
  drain env;
  Alcotest.check states_testable
    "no transitions when already Active" [] (List.rev !obs)

let () =
  Alcotest.run "pctl phase3 systemctl/in_mem"
    [
      ( "in_mem",
        [
          Alcotest.test_case "start transitions" `Quick test_start_transitions;
          Alcotest.test_case "stop transitions" `Quick test_stop_transitions;
          Alcotest.test_case "unit_state unknown" `Quick test_unit_state_unknown;
          Alcotest.test_case "fail_next_start" `Quick test_fail_next_start;
          Alcotest.test_case "restart transitions" `Quick test_restart_transitions;
          Alcotest.test_case "daemon_reload no-op" `Quick test_daemon_reload_noop;
          Alcotest.test_case "push_state notifies subscribers" `Quick
            test_push_state_notifies;
          Alcotest.test_case "subscribers_count" `Quick test_subscribers_count;
          Alcotest.test_case "inspect sorted" `Quick test_inspect_sorted;
          Alcotest.test_case "idempotent start" `Quick test_idempotent_start;
        ] );
    ]
