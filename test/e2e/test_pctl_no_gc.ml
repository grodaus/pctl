(* e2e: PCTL_NO_GC=1 skips the opportunistic sweep.
 *
 * Same setup as test_gc: up project a, delete its path, trigger a
 * mutating command. With PCTL_NO_GC=1 set, project a's row should
 * STILL be present after the second up. *)

let () =
  Harness.skip_or_run ~name:"test_pctl_no_gc" @@ fun () ->
  let owned = Harness.setup ~services:[ Harness.service "web" ] in
  let a = Harness.scratch_of owned in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PCTL_NO_GC" "";
      Harness.teardown owned)
    (fun () ->
      Harness.check_rc_zero ~label:"up(a)" (Harness.up ~scratch:a);
      let id_a_s = Schema.Project_id.to_string (Harness.project_id a) in
      Harness.rm_rf a.project_dir;
      (* Flip the env var BEFORE the second up. *)
      Unix.putenv "PCTL_NO_GC" "1";
      Harness.with_sibling ~of_:a ~prefix:"pctl-e2e-nogc-b"
        ~services:[ Harness.service "api" ]
      @@ fun b ->
      Harness.check_rc_zero ~label:"up(b)" (Harness.up ~scratch:b);
      (* PCTL_NO_GC=1 => project a's row should still be around. *)
      let rc, out = Harness.list () in
      Harness.check_rc_zero ~label:"list" (rc, "");
      Harness.assert_contains ~label:"PCTL_NO_GC=1 preserved project a" out
        id_a_s;
      Printf.printf "test_pctl_no_gc OK — env guard skipped the sweep\n")
