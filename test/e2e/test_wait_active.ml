(* e2e parity: pctl up --wait blocks until every service (no probe) is
 * active. Oracle: tests/e2e/wait_test.nu (probe variant) and wait_pctl_host_test.
 * This variant covers the no-probe unit-state path. *)

let bash = "/run/current-system/sw/bin/bash"

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_wait_active — %s\n" why;
      exit 0
  | None ->
      let web =
        {
          Harness.name = "web";
          probe = None;
          service_config =
            [
              ("Type", "simple");
              ( "ExecStart",
                Printf.sprintf
                  "%s -c 'exec %s -c \"while true; do sleep 3600; done\"'"
                  bash bash );
              ("Slice", "pctl-@@PROJECT@@.slice");
            ];
          workspace = None;
        }
      in
      Harness.with_scratch ~services:[ web ]
      @@ fun scratch ->
      let t0 = Unix.gettimeofday () in
      let rc = Harness.up_wait ~scratch ~timeout:10 () in
      let elapsed = Unix.gettimeofday () -. t0 in
      if rc <> 0 then Alcotest.failf "up --wait exit=%d" rc;
      if elapsed > 8.0 then
        Alcotest.failf "up --wait took too long (%.2fs > 8s)" elapsed;
      (* Verify the unit is active. *)
      let id = Harness.project_id scratch in
      let id_s = Schema.Project_id.to_string id in
      let web_unit = Printf.sprintf "pctl-%s-web.service" id_s in
      Alcotest.(check bool)
        (Printf.sprintf "web %s active" web_unit)
        true (Harness.is_active web_unit);
      print_endline "test_wait_active OK"
