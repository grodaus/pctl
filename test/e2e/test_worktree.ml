(* e2e parity: two worktrees get distinct ids; taking one down does not
 * affect the other.
 *
 * Each scratch has its own registry AND its own systemd --user, and
 * Unix.putenv overwrites the globals that select both, so every
 * operation and every assertion has to name the scratch it is about:
 * `systemctl --user is-active` only ever answers about the manager the
 * environment currently points at.
 *
 * A and B are in separate managers, so the down-isolation assertion below
 * cannot fail for its own reason: nothing A's down does can reach B's
 * manager. pctl-worktree-isolation-vacuous-3gp weighs what to do about
 * that. *)

let up_in (s : Harness.scratch) =
  Harness.activate s;
  Harness.up ~scratch:s

let down_in (s : Harness.scratch) =
  Harness.activate s;
  Harness.down ~scratch:s

let assert_active_in (s : Harness.scratch) unit_name =
  Harness.activate s;
  Harness.assert_unit_active unit_name

let () =
  Harness.skip_or_run ~name:"test_worktree" @@ fun () ->
  (* Nested, not sequential: the second [with_scratch] spawns a manager and
   * can raise, and a finaliser armed after both would not cover the first
   * one's manager, cgroup or tmpdir. *)
  Harness.with_scratch ~services:[ Harness.service "web" ] @@ fun a ->
  Harness.with_scratch ~services:[ Harness.service "web" ] @@ fun b ->
  Harness.check_rc_zero ~label:"up A" (up_in a);
  Harness.check_rc_zero ~label:"up B" (up_in b);
  let id_a_s = Schema.Project_id.to_string (Harness.project_id a) in
  let id_b_s = Schema.Project_id.to_string (Harness.project_id b) in
  Harness.assert_true ~label:"distinct ids" (id_a_s <> id_b_s);
  assert_active_in a (Harness.slice_name id_a_s);
  assert_active_in b (Harness.slice_name id_b_s);
  assert_active_in a (Harness.service_name id_a_s "web");
  assert_active_in b (Harness.service_name id_b_s "web");
  let read_host s id_s =
    Harness.activate s;
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Pipeline.with_connection ~env ~sw (fun conn ->
        match State.Projects.get_by_id conn ~id:id_s with
        | Some r -> Option.value r.host ~default:""
        | None -> "")
  in
  Harness.assert_true ~label:"A host non-empty"
    (String.length (read_host a id_a_s) > 0);
  Harness.assert_true ~label:"B host non-empty"
    (String.length (read_host b id_b_s) > 0);
  let _ = down_in a in
  Harness.activate b;
  Harness.assert_true ~label:"B slice still active after A down"
    (Harness.is_active (Harness.slice_name id_b_s));
  Harness.assert_true ~label:"B web still active after A down"
    (Harness.is_active (Harness.service_name id_b_s "web"));
  print_endline "test_worktree OK"
