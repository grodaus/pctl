(* e2e parity: reload restarts only the changed service; slice and
 * unchanged services survive. *)

let () =
  Harness.skip_or_run ~name:"test_reload" @@ fun () ->
  Harness.with_scratch ~services:[ Harness.service "web"; Harness.service "db" ]
  @@ fun s ->
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch:s);
  let id = Harness.project_id s in
  let id_s = Schema.Project_id.to_string id in
  let slice = Harness.slice_name id_s in
  let web = Harness.service_name id_s "web" in
  let db = Harness.service_name id_s "db" in
  Harness.assert_unit_active slice;
  Harness.assert_unit_active web;
  Harness.assert_unit_active db;
  let web_ts_before = Harness.active_enter_ts web in
  let db_ts_before = Harness.active_enter_ts db in
  let slice_ts_before = Harness.active_enter_ts slice in
  (* Mutate only web: bump its Description. Rewrite the spec.json. *)
  let web_service =
    {
      Harness.name = "web";
      command = [ "/run/current-system/sw/bin/sleep"; "infinity" ];
      service_config = [ ("Type", "simple"); ("Description", "web-v2") ];
      workspace = None;
      probe = None;
      depends_on = [];
    }
  in
  let new_spec =
    Harness.spec_json ~services:[ web_service; Harness.service "db" ]
  in
  let oc = open_out s.spec_path in
  output_string oc new_spec;
  close_out oc;
  Harness.check_rc_zero ~label:"reload" (Harness.reload ~scratch:s);
  Harness.assert_unit_active web;
  let web_ts_after = Harness.active_enter_ts web in
  Harness.assert_true ~label:"web was restarted"
    (web_ts_after <> web_ts_before && web_ts_after <> "");
  Harness.assert_eq_string ~label:"db NOT restarted" db_ts_before
    (Harness.active_enter_ts db);
  Harness.assert_eq_string ~label:"slice NOT restarted" slice_ts_before
    (Harness.active_enter_ts slice);
  (* Disk content reflects the new body. *)
  let web_disk =
    match
      Harness.read_unit
        ~unit_filename:(Harness.service_filename_for ~id ~service_name:"web")
    with
    | Some c -> c
    | None -> Alcotest.fail "web unit file missing post-reload"
  in
  Harness.assert_contains ~label:"web disk has web-v2" web_disk "web-v2";
  (* Drop db from the spec, so its row is [Removed] against real systemd:
     the file is deleted before [apply_plan], and the stop that follows
     has to take the service down even though its fragment is already
     gone. Nothing else in the e2e suite reloads a service away. *)
  let oc = open_out s.spec_path in
  output_string oc (Harness.spec_json ~services:[ web_service ]);
  close_out oc;
  Harness.check_rc_zero ~label:"reload dropping db" (Harness.reload ~scratch:s);
  Harness.assert_unit_gone (Harness.service_filename_for ~id ~service_name:"db");
  Harness.assert_unit_inactive db;
  Harness.assert_unit_active web;
  print_endline "test_reload OK"
