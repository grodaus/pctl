(* e2e parity: two worktrees get distinct ids; taking one down does not
 * affect the other.
 *
 * Each scratch sets its own PCTL_STATE_DB, but Unix.putenv overwrites
 * the global. So we must point env at the right DB before EACH
 * operation — on-the-fly switching. *)

let set_db (s : Harness.scratch) =
  Unix.putenv "PCTL_STATE_DB"
    (Filename.concat s.xdg_state_home "pctl-state.db")

let up_in (s : Harness.scratch) =
  set_db s;
  Harness.up ~scratch:s

let down_in (s : Harness.scratch) =
  set_db s;
  Harness.down ~scratch:s

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_worktree — %s\n" why;
      exit 0
  | None ->
      let a = Harness.setup ~services:[ Harness.service "web" ] in
      let b = Harness.setup ~services:[ Harness.service "web" ] in
      Fun.protect
        ~finally:(fun () ->
          set_db a;
          Harness.teardown a;
          set_db b;
          Harness.teardown b)
      @@ fun () ->
      let rc_a = up_in a in
      if rc_a <> 0 then Alcotest.failf "up A exit=%d" rc_a;
      let rc_b = up_in b in
      if rc_b <> 0 then Alcotest.failf "up B exit=%d" rc_b;
      let id_a = Harness.project_id a in
      let id_b = Harness.project_id b in
      let id_a_s = Schema.Project_id.to_string id_a in
      let id_b_s = Schema.Project_id.to_string id_b in
      Alcotest.(check bool) "distinct ids" true (id_a_s <> id_b_s);
      Alcotest.(check bool)
        "A slice active" true
        (Harness.wait_active (Printf.sprintf "pctl-%s.slice" id_a_s));
      Alcotest.(check bool)
        "B slice active" true
        (Harness.wait_active (Printf.sprintf "pctl-%s.slice" id_b_s));
      Alcotest.(check bool)
        "A web active" true
        (Harness.wait_active
           (Printf.sprintf "pctl-%s-web.service" id_a_s));
      Alcotest.(check bool)
        "B web active" true
        (Harness.wait_active
           (Printf.sprintf "pctl-%s-web.service" id_b_s));
      let read_host s id_s =
        set_db s;
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        Cli.Common.with_connection ~env ~sw (fun conn ->
            match State.Projects.get_by_id conn ~id:id_s with
            | Some r -> Option.value r.host ~default:""
            | None -> "")
      in
      let host_a = read_host a id_a_s in
      let host_b = read_host b id_b_s in
      Alcotest.(check bool)
        "A host non-empty" true (String.length host_a > 0);
      Alcotest.(check bool)
        "B host non-empty" true (String.length host_b > 0);
      let _ = down_in a in
      Alcotest.(check bool)
        "B slice still active after A down" true
        (Harness.is_active (Printf.sprintf "pctl-%s.slice" id_b_s));
      Alcotest.(check bool)
        "B web still active after A down" true
        (Harness.is_active (Printf.sprintf "pctl-%s-web.service" id_b_s));
      print_endline "test_worktree OK"
