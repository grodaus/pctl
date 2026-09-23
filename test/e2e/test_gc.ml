(* e2e: opportunistic GC sweep — a deleted project path gets its row
 * removed when any other mutating command runs. *)

let () =
  Harness.skip_or_run ~name:"test_gc" @@ fun () ->
  Harness.with_scratch ~services:[ Harness.service "web" ] @@ fun a ->
  Harness.check_rc_zero ~label:"up(a)" (Harness.up ~scratch:a);
  let id_a_s = Schema.Project_id.to_string (Harness.project_id a) in
  (* Simulate "project a deleted on disk" by rm -rf of the project_dir.
   * The row stays in the DB; opportunistic sweep should nuke it on the
   * next mutating command. *)
  Harness.rm_rf a.project_dir;
  (* A second project so we can trigger a mutating command in the same
   * XDG_STATE_HOME. *)
  Harness.with_sibling ~of_:a ~prefix:"pctl-e2e-gc-b"
    ~services:[ Harness.service "api" ]
  @@ fun b ->
  Harness.check_rc_zero ~label:"up(b)" (Harness.up ~scratch:b);
  (* After up(b), opportunistic sweep should have purged project a's row.
   * Listing should not show it. *)
  let rc, out = Harness.list () in
  Harness.check_rc_zero ~label:"list" (rc, "");
  Harness.assert_not_contains ~label:"project a swept from list" out id_a_s;
  (* Slice for a should be stopped. *)
  Harness.assert_unit_inactive (Harness.slice_name id_a_s);
  Printf.printf "test_gc OK — opportunistic sweep removed deleted project\n"
