(* Render — substitute, service/slice golden files. *)

open Schema

let id_demo = Project_id.of_string_exn "demo_abc12345"

let test_substitute_basic () =
  let s = "hello @@PROJECT@@ at @@PROJECT_PATH@@" in
  let got = Render.substitute s ~id:id_demo ~project_path:"/home/me" in
  Alcotest.(check string) "subst both"
    "hello demo_abc12345 at /home/me" got

let test_substitute_no_placeholder () =
  let s = "nothing to replace here" in
  let got = Render.substitute s ~id:id_demo ~project_path:"/x" in
  Alcotest.(check string) "unchanged" s got

let test_substitute_idempotent () =
  let s = "path=@@PROJECT_PATH@@ id=@@PROJECT@@" in
  let once = Render.substitute s ~id:id_demo ~project_path:"/p" in
  let twice = Render.substitute once ~id:id_demo ~project_path:"/p" in
  Alcotest.(check string) "idempotent" once twice

(* QCheck idempotence property. *)

let prop_substitute_idempotent =
  let open QCheck in
  let arb_safe_id =
    Gen.string_size ~gen:(Gen.char_range 'a' 'z') (Gen.int_range 3 10)
    |> make ~print:(fun s -> s)
  in
  let arb_safe_path =
    let seg =
      Gen.string_size ~gen:(Gen.char_range 'a' 'z') (Gen.int_range 1 6)
    in
    Gen.map
      (fun segs -> "/" ^ String.concat "/" segs)
      (Gen.list_size (Gen.int_range 1 3) seg)
    |> make ~print:(fun s -> s)
  in
  Test.make ~count:200 ~name:"substitute idempotent after first pass"
    (triple string arb_safe_id arb_safe_path)
    (fun (body, id_s, path) ->
      let id =
        match Project_id.of_string_opt id_s with
        | Some i -> i
        | None -> Project_id.of_string_exn "fallback_aaaaaaaa"
      in
      (* Defensive gate: if the substituted id/path contains a
       * placeholder token itself, a second pass would re-expand it
       * and the property would fail. arb_safe_id / arb_safe_path
       * generate only [a-z0-9/] today, so neither token can appear;
       * we check all four crossings so widening generators won't
       * silently turn the property flaky. *)
      if
        Test_helpers.contains_substring id_s "@@PROJECT@@"
        || Test_helpers.contains_substring id_s "@@PROJECT_PATH@@"
        || Test_helpers.contains_substring path "@@PROJECT@@"
        || Test_helpers.contains_substring path "@@PROJECT_PATH@@"
      then true
      else
        let once = Render.substitute body ~id ~project_path:path in
        let twice = Render.substitute once ~id ~project_path:path in
        once = twice)

let test_render_simple_service () =
  let svc =
    {
      name = "pg";
      kind = Simple;
      depends_on = [];
      workspace = { cwd = false; writable = false };
      probe = None;
      unit_filename = "pctl-@@PROJECT@@-pg.service";
      service_config =
        [
          ("ExecStart", "/nix/store/xxx/bin/postgres");
          ("Type", "simple");
          ("Restart", "on-failure");
          ("StateDirectory", "pctl-@@PROJECT@@-pg");
          ("Environment", "PGDATA=@@PROJECT_PATH@@");
        ];
    }
  in
  let got =
    Render.service ~service:svc ~id:id_demo ~project_path:"/home/me/project"
  in
  let expected =
    Test_helpers.read_file (Test_helpers.render_fixture "simple_service.expected")
  in
  Alcotest.(check string) "simple service golden" expected got

let test_render_service_with_bindpaths () =
  let svc =
    {
      name = "worker";
      kind = Oneshot;
      depends_on = [];
      workspace = { cwd = true; writable = true };
      probe = None;
      unit_filename = "pctl-@@PROJECT@@-worker.service";
      service_config =
        [
          ("Description", "my custom test service");
          ("ExecStart", "/bin/test");
          ("Type", "oneshot");
          ("ProtectHome", "tmpfs");
          ("BindPaths", "@@PROJECT_PATH@@ /tmp/cache");
          ("WorkingDirectory", "@@PROJECT_PATH@@");
        ];
    }
  in
  let got =
    Render.service ~service:svc ~id:id_demo ~project_path:"/home/me/project"
  in
  let expected =
    Test_helpers.read_file
      (Test_helpers.render_fixture "bindpaths_service.expected")
  in
  Alcotest.(check string) "bindpaths + user description golden" expected got

let test_render_slice () =
  let slc =
    {
      unit_filename = "pctl-@@PROJECT@@.slice";
      slice_config = [ ("CPUWeight", "100"); ("MemoryMax", "4G") ];
    }
  in
  let got =
    Render.slice ~slice:slc ~id:id_demo ~project_path:"/home/me/project"
  in
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
          test_case "substitute basic" `Quick test_substitute_basic;
          test_case "substitute no placeholder" `Quick test_substitute_no_placeholder;
          test_case "substitute idempotent" `Quick test_substitute_idempotent;
          test_case "service golden (simple)" `Quick test_render_simple_service;
          test_case "service golden (bindpaths + user description)" `Quick
            test_render_service_with_bindpaths;
          test_case "slice golden" `Quick test_render_slice;
        ]
        @ List.map QCheck_alcotest.to_alcotest [ prop_substitute_idempotent ]
      );
    ]
