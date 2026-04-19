(* e2e parity: down stops units, removes files. *)

let () =
  Harness.skip_or_run ~name:"test_down" @@ fun () ->
  Harness.with_scratch ~services:[ Harness.service "web" ]
  @@ fun scratch ->
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  let id = Harness.project_id scratch in
  let id_s = Schema.Project_id.to_string id in
  let slice = Harness.slice_name id_s in
  let web = Harness.service_name id_s "web" in
  Harness.assert_unit_active slice;
  Harness.assert_unit_active web;
  Harness.check_rc_zero ~label:"down" (Harness.down ~scratch);
  (* Unit files should be gone. *)
  Harness.assert_unit_gone (Harness.slice_filename_for ~id);
  Harness.assert_unit_gone (Harness.service_filename_for ~id ~service_name:"web");
  Harness.assert_dropin_gone (Harness.service_filename_for ~id ~service_name:"web");
  (* Nothing is active. *)
  Harness.assert_unit_inactive slice;
  Harness.assert_unit_inactive web;
  print_endline "test_down OK"
