(* e2e parity: reload restarts only the changed service; slice and
 * unchanged services survive. *)

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_reload — %s\n" why;
      exit 0
  | None ->
      let s = Harness.setup ~services:[ Harness.service "web"; Harness.service "db" ] in
      Fun.protect
        ~finally:(fun () -> Harness.teardown s)
      @@ fun () ->
      let rc = Harness.up ~scratch:s in
      if rc <> 0 then Alcotest.failf "up exit=%d" rc;
      let id = Harness.project_id s in
      let id_s = Schema.Project_id.to_string id in
      let slice = Printf.sprintf "pctl-%s.slice" id_s in
      let web = Printf.sprintf "pctl-%s-web.service" id_s in
      let db = Printf.sprintf "pctl-%s-db.service" id_s in
      Alcotest.(check bool) "slice active" true (Harness.wait_active slice);
      Alcotest.(check bool) "web active" true (Harness.wait_active web);
      Alcotest.(check bool) "db active" true (Harness.wait_active db);
      let web_ts_before = Harness.active_enter_ts web in
      let db_ts_before = Harness.active_enter_ts db in
      let slice_ts_before = Harness.active_enter_ts slice in
      (* Mutate only web: bump its Description. Rewrite the spec.json. *)
      let web_service =
        {
          Harness.name = "web";
          service_config =
            [
              ("Type", "simple");
              ( "ExecStart",
                Printf.sprintf "%s infinity" "/run/current-system/sw/bin/sleep" );
              ("Slice", "pctl-@@PROJECT@@.slice");
              ("Description", "web-v2 @@PROJECT@@");
            ];
          workspace = None;
        }
      in
      let db_service = Harness.service "db" in
      let new_spec =
        Harness.spec_json ~services:[ web_service; db_service ]
      in
      let oc = open_out s.spec_path in
      output_string oc new_spec;
      close_out oc;
      let rc = Harness.reload ~scratch:s in
      if rc <> 0 then Alcotest.failf "reload exit=%d" rc;
      Alcotest.(check bool) "web re-active" true (Harness.wait_active web);
      let web_ts_after = Harness.active_enter_ts web in
      Alcotest.(check bool) "web was restarted" true
        (web_ts_after <> web_ts_before && web_ts_after <> "");
      let db_ts_after = Harness.active_enter_ts db in
      Alcotest.(check string) "db NOT restarted" db_ts_before db_ts_after;
      let slice_ts_after = Harness.active_enter_ts slice in
      Alcotest.(check string) "slice NOT restarted" slice_ts_before slice_ts_after;
      (* Disk content reflects the new body. *)
      let web_disk =
        match Harness.read_unit ~id
                ~unit_filename:"pctl-@@PROJECT@@-web.service"
        with
        | Some s -> s
        | None -> Alcotest.fail "web unit file missing post-reload"
      in
      let contains h n =
        let hl = String.length h and nl = String.length n in
        let rec go i =
          if i + nl > hl then false
          else if String.sub h i nl = n then true
          else go (i + 1)
        in
        nl = 0 || go 0
      in
      Alcotest.(check bool)
        "web disk has web-v2" true
        (contains web_disk "web-v2");
      print_endline "test_reload OK"
