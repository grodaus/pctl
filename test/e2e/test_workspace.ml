(* e2e parity: workspace.cwd=true + workspace.writable=true. The rendered
 * unit must carry WorkingDirectory=<project path> and BindPaths=<project path>
 * (both fully substituted). *)

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_workspace — %s\n" why;
      exit 0
  | None ->
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
      let rc = Harness.up ~scratch in
      if rc <> 0 then Alcotest.failf "up exit=%d" rc;
      let id = Harness.project_id scratch in
      let id_s = Schema.Project_id.to_string id in
      let writer_unit = Printf.sprintf "pctl-%s-writer.service" id_s in
      Alcotest.(check bool) "writer active" true
        (Harness.wait_active writer_unit);
      let installed =
        match Harness.read_unit ~id
                ~unit_filename:"pctl-@@PROJECT@@-writer.service"
        with
        | Some s -> s
        | None -> Alcotest.fail "writer unit missing"
      in
      let contains h n =
        let hl = String.length h and nl = String.length n in
        let rec go i =
          if i + nl > hl then false
          else if String.sub h i nl = n then true
          else go (i + 1)
        in
        nl = 0 || go 0
      in
      Alcotest.(check bool)
        "no @@PROJECT_PATH@@ left" false
        (contains installed "@@PROJECT_PATH@@");
      Alcotest.(check bool)
        "WorkingDirectory substituted" true
        (contains installed
           (Printf.sprintf "WorkingDirectory=%s" scratch.project_dir));
      Alcotest.(check bool)
        "BindPaths substituted" true
        (contains installed
           (Printf.sprintf "BindPaths=%s" scratch.project_dir));
      let hello = Filename.concat scratch.project_dir "hello" in
      Alcotest.(check bool)
        (Printf.sprintf "bind-mount real: %s exists" hello)
        true (Sys.file_exists hello);
      print_endline "test_workspace OK"
