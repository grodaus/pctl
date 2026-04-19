(* e2e: opportunistic GC sweep — a deleted project path gets its row
 * removed when any other mutating command runs. *)

let () =
  Harness.skip_or_run ~name:"test_gc" @@ fun () ->
  let a = Harness.setup ~services:[ Harness.service "web" ] in
  Fun.protect
    ~finally:(fun () -> Harness.teardown a)
    (fun () ->
      Harness.check_rc_zero ~label:"up(a)" (Harness.up ~scratch:a);
      let id_a_s = Schema.Project_id.to_string (Harness.project_id a) in
      (* Simulate "project a deleted on disk" by rm -rf of the project_dir.
       * The row stays in the DB; opportunistic sweep should nuke it on the
       * next mutating command. *)
      Harness.rm_rf a.project_dir;
      (* A second project so we can trigger a mutating command in the same
       * XDG_STATE_HOME. *)
      let b_tmp = Harness.fresh_tmpdir "pctl-e2e-gc-b" in
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
          (* After up(b), opportunistic sweep should have purged project
           * a's row. Listing should not show it. *)
          let rc, out = Harness.list () in
          Harness.check_rc_zero ~label:"list" rc;
          Harness.assert_not_contains
            ~label:"project a swept from list" out id_a_s;
          (* Slice for a should be stopped. *)
          Harness.assert_unit_inactive (Harness.slice_name id_a_s);
          Printf.printf
            "test_gc OK — opportunistic sweep removed deleted project\n"))
