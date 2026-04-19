(* e2e: pctl list — shows every registered project with its class. *)

let () =
  Harness.skip_or_run ~name:"test_list" @@ fun () ->
  (* Two scratches sharing one XDG_STATE_HOME so their rows land in the
   * same projects table. We set up the first scratch (which puts
   * XDG_STATE_HOME in its tmp), then override the second scratch to use
   * the SAME state home. *)
  let a = Harness.setup ~services:[ Harness.service "web" ] in
  Fun.protect
    ~finally:(fun () -> Harness.teardown a)
    (fun () ->
      Harness.check_rc_zero ~label:"up(a)" (Harness.up ~scratch:a);
      (* Reuse the same XDG_STATE_HOME for project b — manually wire a
       * scratch pointed at a separate project_dir. *)
      let b_tmp = Harness.fresh_tmpdir "pctl-e2e-b" in
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
          let rc, out = Harness.list () in
          Harness.check_rc_zero ~label:"list" rc;
          let id_a = Schema.Project_id.to_string (Harness.project_id a) in
          let id_b = Schema.Project_id.to_string (Harness.project_id b) in
          Harness.assert_contains ~label:"list has project a" out id_a;
          Harness.assert_contains ~label:"list has project b" out id_b;
          (* Both rows should show class=live because the session_id
           * matches the current boot. *)
          Harness.assert_contains ~label:"list has a 'live' row" out "live";
          Printf.printf "test_list OK — saw both projects + live class\n"))
