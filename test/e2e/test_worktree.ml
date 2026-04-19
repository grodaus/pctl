(* e2e parity: two worktrees get distinct ids; taking one down does not
 * affect the other.
 *
 * Each scratch has its own XDG_STATE_HOME, but Unix.putenv overwrites
 * the global. So we must point the env at the right state home before
 * EACH operation — on-the-fly switching. *)

let set_db (s : Harness.scratch) =
  Unix.putenv "XDG_STATE_HOME" s.xdg_state_home

let up_in (s : Harness.scratch) =
  set_db s;
  Harness.up ~scratch:s

let down_in (s : Harness.scratch) =
  set_db s;
  Harness.down ~scratch:s

let () =
  Harness.skip_or_run ~name:"test_worktree" @@ fun () ->
  let a = Harness.setup ~services:[ Harness.service "web" ] in
  let b = Harness.setup ~services:[ Harness.service "web" ] in
  Fun.protect
    ~finally:(fun () ->
      set_db a;
      Harness.teardown a;
      set_db b;
      Harness.teardown b)
  @@ fun () ->
  Harness.check_rc_zero ~label:"up A" (up_in a);
  Harness.check_rc_zero ~label:"up B" (up_in b);
  let id_a_s = Schema.Project_id.to_string (Harness.project_id a) in
  let id_b_s = Schema.Project_id.to_string (Harness.project_id b) in
  Harness.assert_true ~label:"distinct ids" (id_a_s <> id_b_s);
  Harness.assert_unit_active (Harness.slice_name id_a_s);
  Harness.assert_unit_active (Harness.slice_name id_b_s);
  Harness.assert_unit_active (Harness.service_name id_a_s "web");
  Harness.assert_unit_active (Harness.service_name id_b_s "web");
  let read_host s id_s =
    set_db s;
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Common.with_connection ~env ~sw (fun conn ->
        match State.Projects.get_by_id conn ~id:id_s with
        | Some r -> Option.value r.host ~default:""
        | None -> "")
  in
  Harness.assert_true ~label:"A host non-empty"
    (String.length (read_host a id_a_s) > 0);
  Harness.assert_true ~label:"B host non-empty"
    (String.length (read_host b id_b_s) > 0);
  let _ = down_in a in
  Harness.assert_true ~label:"B slice still active after A down"
    (Harness.is_active (Harness.slice_name id_b_s));
  Harness.assert_true ~label:"B web still active after A down"
    (Harness.is_active (Harness.service_name id_b_s "web"));
  print_endline "test_worktree OK"
