(* e2e: pctl status — shells out to systemctl; exits 0 regardless of
 * unit state (tolerates inactive post-down, per Nushell oracle). *)

let () =
  Harness.skip_or_run ~name:"test_status" @@ fun () ->
  Harness.with_scratch ~services:[ Harness.service "svc" ]
  @@ fun scratch ->
  (* Scenario 1: after up, status on the slice should exit 0. *)
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  let id_s = Schema.Project_id.to_string (Harness.project_id scratch) in
  Harness.assert_unit_active (Harness.slice_name id_s);
  Harness.check_rc_zero ~label:"status (up)" (Harness.status ~scratch ());
  (* Scenario 2: after down, status still returns 0 (Nushell oracle
   * tolerates inactive units). *)
  let (_ : int) = Harness.down ~scratch in
  Harness.check_rc_zero ~label:"status (after down)"
    (Harness.status ~scratch ());
  Printf.printf "test_status OK\n"
