(* e2e parity: two worktrees get distinct ids and hosts; taking one down
 * does not affect the other.
 *
 * One manager and one registry for both, as a developer's two worktrees
 * have: B is a sibling of A. That is what gives the down-isolation check
 * something to catch — A's StopUnit calls reach the manager holding B's
 * units — and what makes distinct hosts something Host_alloc guarantees
 * from one registry's taken set, rather than two registries' ids merely
 * hashing apart. *)

let () =
  Harness.skip_or_run ~name:"test_worktree" @@ fun () ->
  Harness.with_scratch ~services:[ Harness.service "web" ] @@ fun a ->
  Harness.with_sibling ~of_:a ~prefix:"pctl-e2e-worktree-b"
    ~services:[ Harness.service "web" ]
  @@ fun b ->
  Harness.check_rc_zero ~label:"up A" (Harness.up ~scratch:a);
  Harness.check_rc_zero ~label:"up B" (Harness.up ~scratch:b);
  let id_a_s = Schema.Project_id.to_string (Harness.project_id a) in
  let id_b_s = Schema.Project_id.to_string (Harness.project_id b) in
  Harness.assert_true ~label:"distinct ids" (id_a_s <> id_b_s);
  List.iter Harness.assert_unit_active
    [
      Harness.slice_name id_a_s;
      Harness.slice_name id_b_s;
      Harness.service_name id_a_s "web";
      Harness.service_name id_b_s "web";
    ];
  let host id_s =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Pipeline.with_connection ~env ~sw (fun conn ->
        match State.Projects.get_by_id conn ~id:id_s with
        | Some { host = Some h; _ } -> h
        | Some { host = None; _ } -> Alcotest.failf "%s has no host" id_s
        | None -> Alcotest.failf "%s is not registered" id_s)
  in
  let host_a = host id_a_s and host_b = host id_b_s in
  Harness.assert_true
    ~label:(Printf.sprintf "distinct hosts (%s, %s)" host_a host_b)
    (host_a <> host_b);
  Harness.check_rc_zero ~label:"down A" (Harness.down ~scratch:a);
  Harness.assert_unit_inactive (Harness.slice_name id_a_s);
  Harness.assert_true ~label:"B slice still active after A down"
    (Harness.is_active (Harness.slice_name id_b_s));
  Harness.assert_true ~label:"B web still active after A down"
    (Harness.is_active (Harness.service_name id_b_s "web"));
  print_endline "test_worktree OK"
