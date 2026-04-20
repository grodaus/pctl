(* Spec — loader exercised against real fixtures produced by
 * nix/lib/mkProject.nix and hand-crafted malformed inputs. *)

open Schema

let check_raises_pctl ~name ~predicate f =
  try
    ignore (f ());
    Alcotest.fail (Printf.sprintf "%s: expected Pctl_error, got no raise" name)
  with
  | Pctl_error e when predicate e -> ()
  | Pctl_error e ->
      Alcotest.fail
        (Printf.sprintf "%s: unexpected Pctl_error: %s" name (render_error e))
  | exn ->
      Alcotest.fail
        (Printf.sprintf "%s: unexpected exception %s" name
           (Printexc.to_string exn))

let test_spec_load_single () =
  let spec = Spec.load (Fpath.v (Test_helpers.spec_fixture "single")) in
  Alcotest.(check int) "version" 2 spec.version;
  Alcotest.(check int) "service count" 1 (StringMap.cardinal spec.services);
  let pg = StringMap.find "pg" spec.services in
  Alcotest.(check string) "name" "pg" pg.name;
  Alcotest.(check bool) "kind" true (pg.kind = Simple);
  Alcotest.(check (list string)) "depends_on" [] pg.depends_on;
  Alcotest.(check bool) "workspace.cwd" false pg.workspace.cwd;
  Alcotest.(check bool) "workspace.writable" false pg.workspace.writable;
  Alcotest.(check bool) "probe is None" true (pg.probe = None);
  let sc = pg.service_config in
  Alcotest.(check (option string))
    "ExecStart" (Some "/bin/true") (List.assoc_opt "ExecStart" sc);
  Alcotest.(check (option string))
    "Type" (Some "simple") (List.assoc_opt "Type" sc)

let test_spec_load_multi_depends_on () =
  let spec = Spec.load (Fpath.v (Test_helpers.spec_fixture "multi")) in
  Alcotest.(check int) "service count" 3 (StringMap.cardinal spec.services);
  let server = StringMap.find "server" spec.services in
  Alcotest.(check (list string))
    "server depends_on" [ "pg"; "migrate" ] server.depends_on;
  let pg = StringMap.find "pg" spec.services in
  Alcotest.(check (list string)) "pg depends_on" [ "migrate" ] pg.depends_on;
  let migrate = StringMap.find "migrate" spec.services in
  Alcotest.(check (list string)) "migrate depends_on" [] migrate.depends_on

let test_spec_load_probe () =
  let spec = Spec.load (Fpath.v (Test_helpers.spec_fixture "probe")) in
  let pg = StringMap.find "pg" spec.services in
  match pg.probe with
  | None -> Alcotest.fail "expected probe to be present"
  | Some p ->
      Alcotest.(check (list string)) "exec" [ "/bin/true" ] p.exec;
      Alcotest.(check int) "period_seconds" 2 p.period_seconds;
      Alcotest.(check int) "timeout_seconds" 60 p.timeout_seconds

let test_spec_load_workspace () =
  let spec = Spec.load (Fpath.v (Test_helpers.spec_fixture "workspace")) in
  let worker = StringMap.find "worker" spec.services in
  Alcotest.(check bool) "cwd" true worker.workspace.cwd;
  Alcotest.(check bool) "writable" true worker.workspace.writable

let test_spec_load_missing_file () =
  check_raises_pctl ~name:"missing file"
    ~predicate:(function Spec_not_found _ -> true | _ -> false) (fun () ->
      Spec.load (Fpath.v "/nonexistent/pctl-spec.json"))

let test_spec_load_parse_error () =
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-bad-" ~contents:"{not json"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"bad JSON"
        ~predicate:(function Spec_parse _ -> true | _ -> false) (fun () ->
          Spec.load (Fpath.v path)))

let test_spec_load_unknown_version () =
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-v99-"
      ~contents:
        "{\"version\": 99, \"slice\": {}, \"services\": {}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"unknown version"
        ~predicate:(function Spec_unknown_version 99 -> true | _ -> false)
        (fun () -> Spec.load (Fpath.v path)))

let test_spec_load_v1_rejected () =
  (* v1 was the placeholder-carrying schema; v2 dropped the placeholder
   * convention. Loader rejects v1 with a clear version error. *)
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-v1-"
      ~contents:
        "{\"version\": 1, \"slice\": {}, \"services\": {}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"v1 rejected"
        ~predicate:(function Spec_unknown_version 1 -> true | _ -> false)
        (fun () -> Spec.load (Fpath.v path)))

let test_spec_load_missing_version () =
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-novers-"
      ~contents:"{\"slice\": {}, \"services\": {}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing version"
        ~predicate:(function Spec_parse _ -> true | _ -> false) (fun () ->
          Spec.load (Fpath.v path)))

let test_spec_load_missing_slice () =
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-noslice-"
      ~contents:"{\"version\": 2, \"services\": {}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing slice"
        ~predicate:(function Spec_parse _ -> true | _ -> false) (fun () ->
          Spec.load (Fpath.v path)))

let test_spec_load_missing_services () =
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-nosvc-"
      ~contents:"{\"version\": 2, \"slice\": {}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing services"
        ~predicate:(function Spec_parse _ -> true | _ -> false) (fun () ->
          Spec.load (Fpath.v path)))

let test_spec_load_missing_kind () =
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-nokind-"
      ~contents:
        "{\"version\": 2, \"slice\": {}, \
         \"services\": {\"pg\": {\"service_config\": {}}}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing kind"
        ~predicate:(function
          | Spec_parse { msg; _ } ->
              Test_helpers.contains_substring msg "kind"
          | _ -> false)
        (fun () -> Spec.load (Fpath.v path)))

let test_spec_load_missing_service_config () =
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-nosc-"
      ~contents:
        "{\"version\": 2, \"slice\": {}, \
         \"services\": {\"pg\": {\"kind\": \"simple\"}}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing service_config"
        ~predicate:(function
          | Spec_parse { msg; _ } ->
              Test_helpers.contains_substring msg "service_config"
          | _ -> false)
        (fun () -> Spec.load (Fpath.v path)))

let test_spec_load_bad_service_config_value () =
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-badsc-"
      ~contents:
        "{\"version\": 2, \"slice\": {}, \
         \"services\": {\"pg\": {\"kind\": \"simple\", \
         \"service_config\": {\"ExecStart\": 42}}}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"non-string service_config value"
        ~predicate:(function
          | Spec_parse { msg; _ } ->
              Test_helpers.contains_substring msg "ExecStart"
          | _ -> false)
        (fun () -> Spec.load (Fpath.v path)))

let test_spec_load_bad_kind () =
  let path =
    Test_helpers.write_temp_file ~prefix:"pctl-badkind-"
      ~contents:
        "{\"version\": 2, \"slice\": {}, \
         \"services\": {\"pg\": {\"kind\": \"zombie\", \
         \"service_config\": {}}}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"unknown kind"
        ~predicate:(function
          | Spec_parse { msg; _ } ->
              Test_helpers.contains_substring msg "zombie"
          | _ -> false)
        (fun () -> Spec.load (Fpath.v path)))

let () =
  let open Alcotest in
  run "pctl spec"
    [
      ( "spec",
        [
          test_case "load single-service fixture" `Quick test_spec_load_single;
          test_case "load multi-service with dependsOn" `Quick
            test_spec_load_multi_depends_on;
          test_case "load readinessProbe fixture" `Quick test_spec_load_probe;
          test_case "load workspace fixture" `Quick test_spec_load_workspace;
          test_case "missing file -> Spec_not_found" `Quick
            test_spec_load_missing_file;
          test_case "bad JSON -> Spec_parse" `Quick test_spec_load_parse_error;
          test_case "version=99 -> Spec_unknown_version" `Quick
            test_spec_load_unknown_version;
          test_case "v1 -> Spec_unknown_version" `Quick test_spec_load_v1_rejected;
          test_case "missing version -> Spec_parse" `Quick
            test_spec_load_missing_version;
          test_case "missing slice -> Spec_parse" `Quick
            test_spec_load_missing_slice;
          test_case "missing services -> Spec_parse" `Quick
            test_spec_load_missing_services;
          test_case "missing kind -> Spec_parse" `Quick
            test_spec_load_missing_kind;
          test_case "missing service_config -> Spec_parse" `Quick
            test_spec_load_missing_service_config;
          test_case "non-string service_config value -> Spec_parse" `Quick
            test_spec_load_bad_service_config_value;
          test_case "unknown kind -> Spec_parse" `Quick test_spec_load_bad_kind;
        ] );
    ]
