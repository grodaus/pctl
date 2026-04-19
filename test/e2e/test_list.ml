(* e2e: pctl list — shows every registered project with its class. *)

let contains h n =
  let hl = String.length h and nl = String.length n in
  let rec go i =
    if i + nl > hl then false
    else if String.sub h i nl = n then true
    else go (i + 1)
  in
  nl = 0 || go 0

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_list — %s\n" why;
      exit 0
  | None ->
      (* Two scratches sharing one XDG_STATE_HOME so their rows land in
       * the same projects table. We set up the first scratch (which
       * puts XDG_STATE_HOME in its tmp), then override the second
       * scratch to use the SAME state home. *)
      let a = Harness.setup ~services:[ Harness.service "web" ] in
      Fun.protect
        ~finally:(fun () -> Harness.teardown a)
        (fun () ->
          (* up project a. *)
          let rc = Harness.up ~scratch:a in
          if rc <> 0 then Alcotest.failf "up(a) exit=%d" rc;
          (* Reuse the same XDG_STATE_HOME for project b — manually
           * wire a scratch pointed at a separate project_dir. *)
          let b_tmp = Harness.fresh_tmpdir "pctl-e2e-b" in
          let b_project_dir = Filename.concat b_tmp "project" in
          Unix.mkdir b_project_dir 0o700;
          let b_spec_path = Filename.concat b_tmp "spec.json" in
          let oc = open_out b_spec_path in
          output_string oc
            (Harness.spec_json ~services:[ Harness.service "api" ]);
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
              let rc = Harness.up ~scratch:b in
              if rc <> 0 then Alcotest.failf "up(b) exit=%d" rc;
              let rc, out = Harness.list () in
              if rc <> 0 then
                Alcotest.failf "list exit=%d stdout=%s" rc out;
              let id_a =
                Schema.Project_id.to_string (Harness.project_id a)
              in
              let id_b =
                Schema.Project_id.to_string (Harness.project_id b)
              in
              if not (contains out id_a) then
                Alcotest.failf "list output missing project a (%s):\n%s"
                  id_a out;
              if not (contains out id_b) then
                Alcotest.failf "list output missing project b (%s):\n%s"
                  id_b out;
              (* Both rows should show class=live because the session_id
               * matches the current boot. *)
              if not (contains out "live") then
                Alcotest.failf "list should show at least one 'live' row:\n%s"
                  out;
              Printf.printf "test_list OK — saw both projects + live class\n"));
      ()
