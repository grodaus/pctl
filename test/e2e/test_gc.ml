(* e2e: opportunistic GC sweep — a deleted project path gets its row
 * removed when any other mutating command runs. *)

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_gc — %s\n" why;
      exit 0
  | None ->
      let a = Harness.setup ~services:[ Harness.service "web" ] in
      Fun.protect
        ~finally:(fun () -> Harness.teardown a)
        (fun () ->
          let rc = Harness.up ~scratch:a in
          if rc <> 0 then Alcotest.failf "up(a) exit=%d" rc;
          let id_a = Harness.project_id a in
          let id_a_s = Schema.Project_id.to_string id_a in
          (* Simulate "project a deleted on disk" by rm -rf of the
           * project_dir. The row stays in the DB; opportunistic sweep
           * should nuke it on the next mutating command. *)
          Harness.rm_rf a.project_dir;
          (* A second project so we can trigger a mutating command in
           * the same XDG_STATE_HOME. *)
          let b_tmp = Harness.fresh_tmpdir "pctl-e2e-gc-b" in
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
              (* After up(b), opportunistic sweep should have purged
               * project a's row. Listing should not show it. *)
              let rc, out = Harness.list () in
              if rc <> 0 then
                Alcotest.failf "list exit=%d stdout=%s" rc out;
              let contains h n =
                let hl = String.length h and nl = String.length n in
                let rec go i =
                  if i + nl > hl then false
                  else if String.sub h i nl = n then true
                  else go (i + 1)
                in
                nl = 0 || go 0
              in
              if contains out id_a_s then
                Alcotest.failf
                  "opportunistic sweep failed — project a (%s) still \
                   listed:\n%s"
                  id_a_s out;
              (* Slice for a should be stopped. *)
              let slice_a = Printf.sprintf "pctl-%s.slice" id_a_s in
              if Harness.is_active slice_a then
                Alcotest.failf "slice %s still active after sweep" slice_a;
              Printf.printf
                "test_gc OK — opportunistic sweep removed deleted project\n"))
