(* e2e: pctl status — shells out to systemctl; exits 0 regardless of
 * unit state (tolerates inactive post-down, per Nushell oracle). *)

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_status — %s\n" why;
      exit 0
  | None ->
      Harness.with_scratch ~services:[ Harness.service "svc" ]
      @@ fun scratch ->
      (* Scenario 1: after up, status on the slice should exit 0. *)
      let rc = Harness.up ~scratch in
      if rc <> 0 then Alcotest.failf "up exit=%d" rc;
      let id = Harness.project_id scratch in
      let id_s = Schema.Project_id.to_string id in
      let slice = Printf.sprintf "pctl-%s.slice" id_s in
      if not (Harness.wait_active slice) then
        Alcotest.failf "slice did not reach active";
      let rc = Harness.status ~scratch () in
      if rc <> 0 then Alcotest.failf "status (up) exit=%d (expected 0)" rc;
      (* Scenario 2: after down, status still returns 0 (Nushell
       * oracle tolerates inactive units). *)
      let (_ : int) = Harness.down ~scratch in
      let rc = Harness.status ~scratch () in
      if rc <> 0 then
        Alcotest.failf "status (after down) exit=%d (expected 0 — \
                         Nushell oracle tolerates inactive)"
          rc;
      Printf.printf "test_status OK\n"
