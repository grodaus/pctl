(* e2e: PCTL_NO_GC=1 skips the opportunistic sweep.
 *
 * Same setup as test_gc: up project a, delete its path, trigger a
 * mutating command. With PCTL_NO_GC=1 set, project a's row should
 * STILL be present after the second up. *)

let () =
  Harness.skip_or_run ~name:"test_pctl_no_gc" @@ fun () ->
  let a = Harness.setup ~services:[ Harness.service "web" ] in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PCTL_NO_GC" "";
      Harness.teardown a)
    (fun () ->
      Harness.check_rc_zero ~label:"up(a)" (Harness.up ~scratch:a);
      let id_a_s = Schema.Project_id.to_string (Harness.project_id a) in
      Harness.rm_rf a.project_dir;
      (* Flip the env var BEFORE the second up. *)
      Unix.putenv "PCTL_NO_GC" "1";
      let b_tmp = Harness.fresh_tmpdir "pctl-e2e-nogc-b" in
      let b_project_dir = Filename.concat b_tmp "project" in
      Unix.mkdir b_project_dir 0o700;
      let b_spec_path = Filename.concat b_tmp "spec.json" in
      let oc = open_out b_spec_path in
      output_string oc (Harness.spec_json ~services:[ Harness.service "api" ]);
      close_out oc;
      let b : Harness.scratch =
        {
          tmp = b_tmp;
          project_dir = b_project_dir;
          spec_path = b_spec_path;
          xdg_state_home = a.xdg_state_home;
          xdg_state_home_prev = None;
        }
      in
      Fun.protect
        ~finally:(fun () ->
          (try ignore (Harness.down ~scratch:b) with _ -> ());
          Harness.rm_rf b_tmp)
        (fun () ->
          Harness.check_rc_zero ~label:"up(b)" (Harness.up ~scratch:b);
          (* PCTL_NO_GC=1 => project a's row should still be around. *)
          let rc, out = Harness.list () in
          Harness.check_rc_zero ~label:"list" rc;
          Harness.assert_contains ~label:"PCTL_NO_GC=1 preserved project a"
            out id_a_s;
          Printf.printf "test_pctl_no_gc OK — env guard skipped the sweep\n"))
