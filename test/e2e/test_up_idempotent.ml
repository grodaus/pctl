(* e2e parity: running up twice converges — the second diff is all Unchanged. *)

let () =
  Harness.skip_or_run ~name:"test_up_idempotent" @@ fun () ->
  Harness.with_scratch
    ~services:[ Harness.service "web"; Harness.service "api" ]
  @@ fun scratch ->
  Harness.check_rc_zero ~label:"first up" (Harness.up ~scratch);
  (* Read the persisted host to check it's stable across ups. *)
  let id_s = Schema.Project_id.to_string (Harness.project_id scratch) in
  let read_host () =
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    Cli.Pipeline.with_connection ~env ~sw (fun conn ->
        match State.Projects.get_by_id conn ~id:id_s with
        | Some r -> Option.value r.host ~default:""
        | None -> "")
  in
  let host_before = read_host () in
  Harness.assert_true ~label:"host recorded after first up"
    (String.length host_before > 0);
  (* Second run — must not change the host, and its diff, read from
   * user.control, must be all Unchanged. *)
  let rc, stdout =
    Harness.with_captured_stdout (fun () ->
        Eio_main.run @@ fun env ->
        Eio.Switch.run @@ fun sw ->
        Cli.Pipeline.Prod.reload ~sw ~env ~tree:scratch.spec_path
          ~path:scratch.project_dir ())
  in
  Harness.check_rc_zero ~label:"second run" (rc, stdout);
  Harness.assert_eq_string ~label:"host stable across ups" host_before
    (read_host ());
  Harness.assert_true
    ~label:("second-run plan is all Unchanged, got: " ^ stdout)
    (Harness.contains stdout "+0 ~0 =3 -0");
  print_endline "test_up_idempotent OK"
