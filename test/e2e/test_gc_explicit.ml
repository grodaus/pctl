(* e2e: pctl gc --yes purges every non-Live project. *)

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_gc_explicit — %s\n" why;
      exit 0
  | None ->
      let a = Harness.setup ~services:[ Harness.service "web" ] in
      Fun.protect
        ~finally:(fun () -> Harness.teardown a)
        (fun () ->
          let rc = Harness.up ~scratch:a in
          if rc <> 0 then Alcotest.failf "up(a) exit=%d" rc;
          (* down project a so it's no longer Live (session_id cleared
           * by Down). *)
          let (_ : int) = Harness.down ~scratch:a in
          let id_a_s = Schema.Project_id.to_string (Harness.project_id a) in
          (* Disable opportunistic sweep from affecting this path;
           * we want gc --yes to do the removal explicitly. Keep the
           * project_dir on disk so class is Orphan (not Unknown). *)
          let rc, out = Harness.gc ~yes:true () in
          if rc <> 0 then Alcotest.failf "gc --yes exit=%d out=%s" rc out;
          (* After purge, list should be empty of project a. *)
          let rc, list_out = Harness.list () in
          if rc <> 0 then Alcotest.failf "list exit=%d" rc;
          let contains h n =
            let hl = String.length h and nl = String.length n in
            let rec go i =
              if i + nl > hl then false
              else if String.sub h i nl = n then true
              else go (i + 1)
            in
            nl = 0 || go 0
          in
          if contains list_out id_a_s then
            Alcotest.failf "pctl gc --yes failed to remove %s:\n%s"
              id_a_s list_out;
          Printf.printf "test_gc_explicit OK — purge cleared non-Live row\n")
