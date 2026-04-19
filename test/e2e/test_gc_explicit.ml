(* e2e: pctl gc --yes purges every non-Live project. *)

let () =
  Harness.skip_or_run ~name:"test_gc_explicit" @@ fun () ->
  let a = Harness.setup ~services:[ Harness.service "web" ] in
  Fun.protect
    ~finally:(fun () -> Harness.teardown a)
    (fun () ->
      Harness.check_rc_zero ~label:"up(a)" (Harness.up ~scratch:a);
      (* Down project a so it's no longer Live (session_id cleared by Down). *)
      let (_ : int) = Harness.down ~scratch:a in
      let id_a_s = Schema.Project_id.to_string (Harness.project_id a) in
      (* Disable opportunistic sweep from affecting this path; we want gc
       * --yes to do the removal explicitly. Keep the project_dir on disk
       * so class is Orphan (not Unknown). *)
      let rc, out = Harness.gc ~yes:true () in
      if rc <> 0 then Alcotest.failf "gc --yes exit=%d out=%s" rc out;
      (* After purge, list should be empty of project a. *)
      let rc, list_out = Harness.list () in
      Harness.check_rc_zero ~label:"list" rc;
      Harness.assert_not_contains ~label:"gc --yes cleared project a"
        list_out id_a_s;
      Printf.printf "test_gc_explicit OK — purge cleared non-Live row\n")
