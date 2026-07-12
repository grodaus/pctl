(* Regression for issue #8.
 *
 * Before the fix, a service declaring depends_on=[...] had its start
 * job queued by systemd (Requires=/After= ordering) while the unit
 * itself stayed at ActiveState=inactive until the chain ran. Probe's
 * initial read saw that "inactive", treated it as terminal, and
 * reported the service as state=inactive in microseconds — even
 * though ExecStart had not yet been invoked.
 *
 * This test wires a slow migration → an app service that depends on
 * it, calls `pctl up --wait`, and asserts (a) rc=0, (b) the app unit
 * is actually active at the end, and (c) the wait lasted at least as
 * long as the migration's delay. Any one of those assertions fails
 * under the old semantics. *)

let bash = "/run/current-system/sw/bin/bash"
let true_bin = "/run/current-system/sw/bin/true"
let sleep_bin = Harness.sleep_bin

let () =
  Harness.skip_or_run ~name:"test_depends_on_wait" @@ fun () ->
  (* migrate: oneshot, deliberately slow (~1.5s) to widen the window
     during which `app` is queued-Inactive. *)
  let migrate : Harness.service_fixture =
    {
      name = "migrate";
      probe = None;
      command =
        [ bash; "-c"; Printf.sprintf "%s 1.5 && %s" sleep_bin true_bin ];
      service_config = [ ("Type", "oneshot"); ("RemainAfterExit", "yes") ];
      workspace = None;
      depends_on = [];
    }
  in
  (* Two apps gated on migrate. Render emits Requires=/After= for the
     dep — exactly the shape that trips the Inactive-as-terminal race.
     Two overlapping chains mirror the tuor report (test-backend and
     test-e2e both blocked on migrate) and make sure the fix survives
     more than one concurrent probe looking up the same pending job. *)
  let app name : Harness.service_fixture =
    {
      name;
      probe = None;
      command = [ sleep_bin; "infinity" ];
      service_config = [ ("Type", "simple") ];
      workspace = None;
      depends_on = [ "migrate" ];
    }
  in
  Harness.with_scratch ~services:[ migrate; app "app"; app "app2" ]
  @@ fun scratch ->
  let t0 = Unix.gettimeofday () in
  Harness.check_rc_zero ~label:"up --wait"
    (Harness.up_wait ~scratch ~timeout:15 ());
  let elapsed = Unix.gettimeofday () -. t0 in
  let id_s = Schema.Project_id.to_string (Harness.project_id scratch) in
  let assert_active svc =
    let unit_name = Harness.service_name id_s svc in
    if not (Harness.is_active unit_name) then
      Alcotest.failf "%s not active after up --wait\n%s" unit_name
        (Harness.unit_diagnostic unit_name)
  in
  List.iter assert_active [ "migrate"; "app"; "app2" ];
  (* Pre-fix, up --wait returned in <100 ms because Probe resolved
     `app` as terminal-Inactive immediately. The migration sleeps 1.5s,
     so any elapsed below ~1s proves the probe skipped the queued job. *)
  if elapsed < 1.0 then
    Alcotest.failf
      "up --wait returned too fast (%.2fs < 1.0s) — likely tripped \
       the Inactive-race from issue #8" elapsed;
  Printf.printf "test_depends_on_wait OK (%.2fs)\n" elapsed
