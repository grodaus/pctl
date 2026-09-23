(* e2e: pctl list — shows every registered project with its class. *)

let () =
  Harness.skip_or_run ~name:"test_list" @@ fun () ->
  (* Two projects sharing one registry so their rows land in the same
   * projects table — see [Harness.sibling_scratch]. *)
  Harness.with_scratch ~services:[ Harness.service "web" ] @@ fun a ->
  Harness.check_rc_zero ~label:"up(a)" (Harness.up ~scratch:a);
  Harness.with_sibling ~of_:a ~prefix:"pctl-e2e-b"
    ~services:[ Harness.service "api" ]
  @@ fun b ->
  Harness.check_rc_zero ~label:"up(b)" (Harness.up ~scratch:b);
  let rc, out = Harness.list () in
  Harness.check_rc_zero ~label:"list" (rc, "");
  let id_a = Schema.Project_id.to_string (Harness.project_id a) in
  let id_b = Schema.Project_id.to_string (Harness.project_id b) in
  Harness.assert_contains ~label:"list has project a" out id_a;
  Harness.assert_contains ~label:"list has project b" out id_b;
  (* Both rows should show class=live because the session_id matches the
   * current boot. *)
  Harness.assert_contains ~label:"list has a 'live' row" out "live";
  Printf.printf "test_list OK — saw both projects + live class\n"
