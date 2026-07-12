(* e2e parity: workspace.cwd=true + workspace.writable=true. The
 * rendered unit must carry WorkingDirectory=<project path> and
 * BindPaths=<project path>, both emitted by Render from the workspace
 * flags (no placeholders involved). *)

let () =
  Harness.skip_or_run ~name:"test_workspace" @@ fun () ->
  let touch = "/run/current-system/sw/bin/touch" in
  (* scratch isn't known until setup; build the service record with a
   * concrete project_dir inside with_scratch so ExecStart gets the real
   * path. *)
  Harness.with_scratch_late (fun (scratch : Harness.scratch) ->
      let writer =
        {
          Harness.name = "writer";
          command = [ touch; Printf.sprintf "%s/hello" scratch.project_dir ];
          service_config =
            [
              ("Type", "oneshot");
              ("RemainAfterExit", "yes");
              ("NoNewPrivileges", "yes");
              ("ProtectSystem", "strict");
            ];
          workspace = Some (true, true);
          probe = None;
          depends_on = [];
        }
      in
      [ writer ])
  @@ fun scratch ->
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  let id = Harness.project_id scratch in
  let id_s = Schema.Project_id.to_string id in
  Harness.assert_unit_active (Harness.service_name id_s "writer");
  let installed =
    match
      Harness.read_unit
        ~unit_filename:(Harness.service_filename_for ~id ~service_name:"writer")
    with
    | Some c -> c
    | None -> Alcotest.fail "writer unit missing"
  in
  Harness.assert_contains ~label:"WorkingDirectory from workspace.cwd" installed
    (Printf.sprintf "WorkingDirectory=%s" scratch.project_dir);
  Harness.assert_contains ~label:"BindPaths from workspace.writable" installed
    (Printf.sprintf "BindPaths=%s" scratch.project_dir);
  let hello = Filename.concat scratch.project_dir "hello" in
  Harness.assert_true
    ~label:(Printf.sprintf "bind-mount real: %s exists" hello)
    (Sys.file_exists hello);
  print_endline "test_workspace OK"
