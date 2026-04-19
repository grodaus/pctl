(* e2e parity: down stops units, removes files. *)

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_down — %s\n" why;
      exit 0
  | None ->
      Harness.with_scratch ~services:[ Harness.service "web" ]
      @@ fun scratch ->
      let rc = Harness.up ~scratch in
      if rc <> 0 then Alcotest.failf "up exit=%d" rc;
      let id = Harness.project_id scratch in
      let id_s = Schema.Project_id.to_string id in
      let slice = Printf.sprintf "pctl-%s.slice" id_s in
      let web = Printf.sprintf "pctl-%s-web.service" id_s in
      Alcotest.(check bool) "slice active" true (Harness.wait_active slice);
      Alcotest.(check bool) "web active" true (Harness.wait_active web);
      let rc_d = Harness.down ~scratch in
      if rc_d <> 0 then Alcotest.failf "down exit=%d" rc_d;
      (* Unit files should be gone. *)
      Alcotest.(check bool)
        "slice file gone" false
        (Harness.unit_exists ~id
           ~unit_filename:"pctl-@@PROJECT@@.slice");
      Alcotest.(check bool)
        "web file gone" false
        (Harness.unit_exists ~id
           ~unit_filename:"pctl-@@PROJECT@@-web.service");
      Alcotest.(check bool)
        "web dropin gone" false
        (Harness.dropin_exists ~id
           ~unit_filename:"pctl-@@PROJECT@@-web.service");
      (* Nothing is active. *)
      Alcotest.(check bool) "slice inactive" false (Harness.is_active slice);
      Alcotest.(check bool) "web inactive" false (Harness.is_active web);
      print_endline "test_down OK"
