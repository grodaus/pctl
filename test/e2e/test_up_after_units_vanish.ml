(* e2e: `pctl up` after the unit files vanished starts everything again.
 *
 * pctl-468: the registry survives a reboot, user.control (tmpfs) does
 * not. Before the fix the diff's left side came from the registry, every
 * row was Unchanged, and up started nothing.
 *
 * The stop is REQUIRED: deleting a unit file kills nothing
 * (test_unit_file_delete_keeps_process.ml), so without it the services
 * stay active and this test would pass without exercising a start.
 *
 * What a real reboot changes that this does not: the boot id (only the
 * gc Live/Orphan class reads it), the host (re-allocated to the same
 * value, since allocation hashes the project id), and systemd's
 * loaded-unit set (emptied here by stop + delete + daemon-reload). The
 * diff reads none of them. *)

let systemctl_user args : int * string =
  let out, rc =
    Harness.run_capture (Printf.sprintf "systemctl --user %s 2>&1" args)
  in
  (rc, out)

let () =
  Harness.skip_or_run ~name:"test_up_after_units_vanish" @@ fun () ->
  Harness.with_scratch ~services:[ Harness.service "web" ] @@ fun scratch ->
  let id = Harness.project_id scratch in
  let id_s = Schema.Project_id.to_string id in
  let slice = Harness.slice_name id_s in
  let web = Harness.service_name id_s "web" in
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  Harness.assert_unit_active web;
  Harness.check_rc_zero ~label:"out-of-band stop"
    (systemctl_user (Printf.sprintf "stop %s" (Filename.quote slice)));
  let st = Unit_store.Fs.create () in
  List.iter
    (fun unit_ -> Unit_store.Fs.remove st ~unit_)
    [
      Schema.Unit_filename.slice ~id;
      Schema.Unit_filename.service ~id ~service:"web";
    ];
  let web_file = Harness.service_filename_for ~id ~service_name:"web" in
  Harness.assert_unit_gone web_file;
  Harness.check_rc_zero ~label:"daemon-reload" (systemctl_user "daemon-reload");
  Harness.assert_unit_inactive web;
  Harness.check_rc_zero ~label:"second up" (Harness.up ~scratch);
  Harness.assert_unit_exists web_file;
  Harness.assert_unit_active web;
  print_endline "test_up_after_units_vanish OK"
