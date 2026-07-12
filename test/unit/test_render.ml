(* Render — service/slice golden files. *)

open Schema

let id_demo = Project_id.of_string_exn "demo_abc12345"

let test_render_simple_service () =
  let svc =
    {
      name = "pg";
      kind = Simple;
      command = [ "/nix/store/xxx/bin/postgres" ];
      depends_on = [];
      workspace = { cwd = false; writable = false };
      probe = None;
      service_config =
        [
          ("Type", "simple");
          ("Restart", "on-failure");
          ("StateDirectory", "pg");
          ("Environment", "PGDATA=/home/me/project");
        ];
    }
  in
  let got =
    Render.service ~service:svc ~id:id_demo
      ~project_path:(Schema.Project_path.of_raw "/home/me/project")
  in
  let expected =
    Test_helpers.read_file (Test_helpers.render_fixture "simple_service.expected")
  in
  Alcotest.(check string) "simple service golden" expected got

let test_render_service_with_workspace () =
  (* workspace.cwd=true + workspace.writable=true — Render produces
   * WorkingDirectory, ProtectHome, BindPaths automatically from the
   * workspace flags. *)
  let svc =
    {
      name = "worker";
      kind = Oneshot;
      command = [ "/bin/test" ];
      depends_on = [];
      workspace = { cwd = true; writable = true };
      probe = None;
      service_config =
        [
          ("Description", "my custom test service");
          ("Type", "oneshot");
        ];
    }
  in
  let got =
    Render.service ~service:svc ~id:id_demo
      ~project_path:(Schema.Project_path.of_raw "/home/me/project")
  in
  let expected =
    Test_helpers.read_file
      (Test_helpers.render_fixture "bindpaths_service.expected")
  in
  Alcotest.(check string) "workspace + user description golden" expected got

let test_render_service_with_deps () =
  let svc =
    {
      name = "server";
      kind = Simple;
      command = [ "/bin/server" ];
      depends_on = [ "pg"; "migrate" ];
      workspace = { cwd = false; writable = false };
      probe = None;
      service_config = [ ("Type", "simple") ];
    }
  in
  let got =
    Render.service ~service:svc ~id:id_demo
      ~project_path:(Schema.Project_path.of_raw "/home/me/project")
  in
  let expected =
    Test_helpers.read_file (Test_helpers.render_fixture "deps_service.expected")
  in
  Alcotest.(check string) "depends_on → Requires/After golden" expected got

let test_exec_start_quoting () =
  let check msg expected command =
    Alcotest.(check string) msg expected (Render.exec_start command)
  in
  check "plain args pass through" "/bin/prog --flag"
    [ "/bin/prog"; "--flag" ];
  check "embedded space is double-quoted" {|prog "hello world"|}
    [ "prog"; "hello world" ];
  check "backslash and double-quote are escaped" {|prog "a\"b\\c"|}
    [ "prog"; {|a"b\c|} ];
  check "literal percent is doubled" "prog 100%%" [ "prog"; "100%" ];
  check "empty arg renders as empty quotes" {|prog ""|} [ "prog"; "" ]

let test_render_slice () =
  let slc =
    { slice_config = [ ("CPUWeight", "100"); ("MemoryMax", "4G") ] }
  in
  let got = Render.slice ~slice:slc ~id:id_demo in
  let expected =
    Test_helpers.read_file (Test_helpers.render_fixture "slice.expected")
  in
  Alcotest.(check string) "slice golden" expected got

let () =
  let open Alcotest in
  run "pctl render"
    [
      ( "render",
        [
          test_case "service golden (simple)" `Quick test_render_simple_service;
          test_case "service golden (workspace + user description)" `Quick
            test_render_service_with_workspace;
          test_case "service golden (depends_on)" `Quick
            test_render_service_with_deps;
          test_case "ExecStart argv quoting" `Quick test_exec_start_quoting;
          test_case "slice golden" `Quick test_render_slice;
        ] );
    ]
