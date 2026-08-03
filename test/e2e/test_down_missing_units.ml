(* e2e: [pctl down] on a registered project whose unit files were deleted
 * out of band must still exit 0.
 *
 * This is the one stop failure the down path tolerates (pctl-8sd narrowed
 * it from "any Pctl_error" to "no-such-unit only"), so it needs a
 * real-systemd guard: the fake can only replay the reply string a test
 * hands it, and what matters is what systemd actually answers.
 *
 * Reaching the case requires a REGISTERED project — [pctl down] on an
 * unregistered path fails earlier with Registry_io (exit 4, measured:
 * "pctl down: no registered project with id 'project_…'") and never
 * enters Lifecycle. So: up, then delete the units out of band, then down.
 *
 * Measured on this host, re-recorded on systemd 260.1 (first taken on 257;
 * both readings agree). This file is what [Systemctl.Bus_errors] points at
 * for the per-unit-type half of the no-such-unit contract, so the readings
 * have to stay current with the host:
 *   - `dbus-send --session … Manager.StopUnit` on an unloaded .service
 *     answers "org.freedesktop.systemd1.NoSuchUnit: Unit x.service not
 *     loaded."; on an unloaded .slice it SUCCEEDS and returns a job path.
 *   - `systemctl --user show -p LoadState` on a never-existing .slice
 *     reports `loaded`, on a never-existing .service `not-found`.
 * systemd synthesises .slice units that have no fragment, so a slice can
 * never be made not-loadable — which is why this test asserts the
 * fragment is gone and the SERVICE is not-found, and does not claim the
 * slice was unloaded. On this version pctl's tolerated branch is
 * therefore not reached even here; the assertions are on the observable
 * contract (down exits 0, nothing left behind), so the test holds either
 * way and fails loudly if some systemd version does answer NoSuchUnit
 * while the tolerance is absent. *)

let systemctl_user args : int * string =
  let out, rc =
    Harness.run_capture (Printf.sprintf "systemctl --user %s 2>&1" args)
  in
  (rc, out)

let load_state unit_name =
  let out, _ =
    Harness.run_capture
      (Printf.sprintf
         "systemctl --user show -p LoadState --value %s 2>/dev/null"
         (Filename.quote unit_name))
  in
  String.trim out

let () =
  Harness.skip_or_run ~name:"test_down_missing_units" @@ fun () ->
  Harness.with_scratch ~services:[ Harness.service "web" ] @@ fun scratch ->
  let id = Harness.project_id scratch in
  let id_s = Schema.Project_id.to_string id in
  let slice = Harness.slice_name id_s in
  let web = Harness.service_name id_s "web" in
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  Harness.assert_unit_active slice;
  Harness.assert_unit_active web;
  (* Out of band: stop the slice, then delete every unit file through the
     same Unit_store.Fs the harness uses for path construction, so this
     test can't drift from the user.control layout. The registry row
     survives, so [pctl down] below runs its stop against units whose
     fragments are gone. *)
  Harness.check_rc_zero ~label:"out-of-band stop"
    (systemctl_user (Printf.sprintf "stop %s" (Filename.quote slice)));
  let slice_file = Harness.slice_filename_for ~id in
  let web_file = Harness.service_filename_for ~id ~service_name:"web" in
  Harness.assert_unit_exists slice_file;
  Harness.assert_unit_exists web_file;
  let st = Unit_store.Fs.create () in
  List.iter
    (fun unit_ -> Unit_store.Fs.remove st ~unit_)
    [
      Schema.Unit_filename.slice ~id;
      Schema.Unit_filename.service ~id ~service:"web";
    ];
  (* Preconditions asserted, not assumed: if any of the above degraded,
     down would run against units that are still present and the
     assertions after it would pass trivially, silently making this a
     duplicate of test_down.ml. *)
  Harness.assert_unit_gone slice_file;
  Harness.assert_unit_gone web_file;
  Harness.assert_dropin_gone web_file;
  Harness.check_rc_zero ~label:"out-of-band daemon-reload"
    (systemctl_user "daemon-reload");
  Harness.assert_unit_inactive slice;
  Harness.assert_eq_string ~label:"service fragment forgotten by systemd"
    "not-found" (load_state web);
  Harness.check_rc_zero ~label:"down (units missing)" (Harness.down ~scratch);
  Harness.assert_unit_gone slice_file;
  Harness.assert_unit_gone web_file;
  print_endline "test_down_missing_units OK"
