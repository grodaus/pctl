(* e2e: deleting a running service's unit file kills nothing.
 *
 * This is the premise of [Lifecycle.apply_row]'s Added → restart arm
 * (pctl-added-restarts-g31, pctl-468): a unit whose fragment is gone
 * stays loaded with its processes running, so StartUnit on it would
 * no-op and leave the process serving the OLD config. Recorded here
 * rather than asserted (pctl-kab).
 *
 * What it looks like: after the delete and a daemon-reload, LoadState
 * reads `not-found` while ActiveState stays `active` and MainPID is
 * unchanged. That combination is the whole point.
 *
 * Measured on systemd 260: such a unit also survives its manager's
 * SIGTERM shutdown — exit.target does not stop it, and its process
 * outlives the manager in the cgroup. So the test stops it itself;
 * the unit is still loaded, which StopUnit needs. *)

let systemctl_user args : int * string =
  let out, rc =
    Harness.run_capture (Printf.sprintf "systemctl --user %s 2>&1" args)
  in
  (rc, out)

let () =
  Harness.skip_or_run ~name:"test_unit_file_delete_keeps_process" @@ fun () ->
  Harness.with_scratch ~services:[ Harness.service "web" ] @@ fun scratch ->
  let id = Harness.project_id scratch in
  let web = Harness.service_name (Schema.Project_id.to_string id) "web" in
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  Harness.assert_unit_active web;
  let main_pid = Harness.show_property ~property:"MainPID" web in
  Harness.assert_true ~label:("web has a MainPID, got " ^ main_pid)
    (main_pid <> "0");
  let web_file = Harness.service_filename_for ~id ~service_name:"web" in
  Unit_store.Fs.remove (Unit_store.Fs.create ())
    ~unit_:(Schema.Unit_filename.service ~id ~service:"web");
  Harness.assert_unit_gone web_file;
  Harness.assert_dropin_gone web_file;
  Harness.check_rc_zero ~label:"daemon-reload" (systemctl_user "daemon-reload");
  Harness.assert_eq_string ~label:"fragment forgotten" "not-found"
    (Harness.load_state web);
  Harness.assert_eq_string ~label:"still active" "active"
    (Harness.show_property ~property:"ActiveState" web);
  Harness.assert_eq_string ~label:"same process" main_pid
    (Harness.show_property ~property:"MainPID" web);
  Harness.check_rc_zero ~label:"stop the fragment-less unit"
    (systemctl_user (Printf.sprintf "stop %s" (Filename.quote web)));
  print_endline "test_unit_file_delete_keeps_process OK"
