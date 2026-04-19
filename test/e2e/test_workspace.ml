(* e2e parity: workspace.cwd=true + workspace.writable=true. The rendered
 * unit must carry WorkingDirectory=<project path> and BindPaths=<project path>
 * (both fully substituted). *)

let () =
  Harness.skip_or_run ~name:"test_workspace" @@ fun () ->
  let touch = "/run/current-system/sw/bin/touch" in
  let writer =
    {
      Harness.name = "writer";
      service_config =
        [
          ("Type", "oneshot");
          ("RemainAfterExit", "yes");
          ("ExecStart", Printf.sprintf "%s @@PROJECT_PATH@@/hello" touch);
          ("Slice", "pctl-@@PROJECT@@.slice");
          ("WorkingDirectory", "@@PROJECT_PATH@@");
          ("ProtectHome", "tmpfs");
          ("BindPaths", "@@PROJECT_PATH@@");
          ("NoNewPrivileges", "yes");
          ("ProtectSystem", "strict");
        ];
      workspace = Some (true, true);
      probe = None;
    }
  in
  Harness.with_scratch ~services:[ writer ]
  @@ fun scratch ->
  Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
  let id = Harness.project_id scratch in
  let id_s = Schema.Project_id.to_string id in
  Harness.assert_unit_active (Harness.service_name id_s "writer");
  let installed =
    match
      Harness.read_unit ~id ~unit_filename:(Harness.service_filename "writer")
    with
    | Some c -> c
    | None -> Alcotest.fail "writer unit missing"
  in
  Harness.assert_not_contains ~label:"no @@PROJECT_PATH@@ left" installed
    "@@PROJECT_PATH@@";
  Harness.assert_contains ~label:"WorkingDirectory substituted" installed
    (Printf.sprintf "WorkingDirectory=%s" scratch.project_dir);
  Harness.assert_contains ~label:"BindPaths substituted" installed
    (Printf.sprintf "BindPaths=%s" scratch.project_dir);
  let hello = Filename.concat scratch.project_dir "hello" in
  Harness.assert_true
    ~label:(Printf.sprintf "bind-mount real: %s exists" hello)
    (Sys.file_exists hello);
  print_endline "test_workspace OK"
