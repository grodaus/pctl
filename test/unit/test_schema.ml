(* Schema ADTs, opaque types, yojson round-trip, error rendering. *)

open Schema

let test_action_strings () =
  Alcotest.(check string) "Added" "added" (action_to_string Added);
  Alcotest.(check string) "Changed" "changed" (action_to_string Changed);
  Alcotest.(check string) "Unchanged" "unchanged" (action_to_string Unchanged);
  Alcotest.(check string) "Removed" "removed" (action_to_string Removed);
  Alcotest.(check string) "Added sym" "+" (action_to_symbol Added);
  Alcotest.(check string) "Changed sym" "~" (action_to_symbol Changed);
  Alcotest.(check string) "Unchanged sym" "=" (action_to_symbol Unchanged);
  Alcotest.(check string) "Removed sym" "-" (action_to_symbol Removed)

let test_state_strings () =
  let pairs =
    [
      (Active, "active");
      (Inactive, "inactive");
      (Failed, "failed");
      (Activating, "activating");
      (Deactivating, "deactivating");
      (Reloading, "reloading");
    ]
  in
  List.iter
    (fun (s, str) ->
      Alcotest.(check string)
        ("to_string " ^ str)
        str (state_to_string s);
      Alcotest.(check (option string))
        ("of_string " ^ str)
        (Some str)
        (Option.map state_to_string (state_of_string str)))
    pairs;
  Alcotest.(check (option string))
    "unknown" None
    (Option.map state_to_string (state_of_string "nope"))

let test_kind_strings () =
  let pairs =
    [
      (Simple, "simple");
      (Oneshot, "oneshot");
      (Forking, "forking");
      (Notify, "notify");
      (Dbus, "dbus");
      (Idle, "idle");
    ]
  in
  List.iter
    (fun (k, str) ->
      Alcotest.(check string) str str (kind_to_string k);
      Alcotest.(check (option string))
        ("of_string " ^ str)
        (Some str)
        (Option.map kind_to_string (kind_of_string str)))
    pairs;
  Alcotest.(check (option string))
    "unknown" None
    (Option.map kind_to_string (kind_of_string "service"))

let test_class_strings () =
  Alcotest.(check string) "live" "live" (class_to_string Live);
  Alcotest.(check string) "orphan" "orphan" (class_to_string Orphan);
  Alcotest.(check string) "unknown" "unknown" (class_to_string Unknown)

let test_project_id_smart_ctor () =
  let ok s =
    Alcotest.(check bool) s true (Option.is_some (Project_id.of_string_opt s))
  in
  let bad s =
    Alcotest.(check bool) s true (Option.is_none (Project_id.of_string_opt s))
  in
  ok "my_project_12345678";
  ok "pctl_736e4605";
  bad "";
  bad "has/slash";
  bad "has\x01bad";
  Alcotest.check_raises "empty raises"
    (Pctl_error (Identity_invalid { path = ""; reason = "empty project id" }))
    (fun () -> ignore (Project_id.of_string_exn ""))

let test_host_smart_ctor () =
  let ok s =
    Alcotest.(check bool) s true (Option.is_some (Host.of_string_opt s))
  in
  let bad s =
    Alcotest.(check bool) s true (Option.is_none (Host.of_string_opt s))
  in
  ok "127.0.0.2";
  ok "127.0.0.254";
  ok "127.0.0.100";
  bad "127.0.0.1";
  bad "127.0.0.255";
  bad "127.0.0.0";
  bad "127.0.0.256";
  bad "10.0.0.5";
  bad "";
  bad "127.0.0."

(* Project_path tests — smart ctor behaviour (tilde expansion, env-var
 * substitution, normalize, absolute-assert). *)

let test_project_path_idempotent () =
  let inputs =
    [ "/a/b"; "/foo"; "/a/b/../c"; "/a/./b"; "/a//b"; "/" ]
  in
  List.iter
    (fun p ->
      let once = Project_path.to_string (Project_path.of_raw p) in
      let twice = Project_path.to_string (Project_path.of_raw once) in
      Alcotest.(check string) ("idempotent: " ^ p) once twice)
    inputs

let test_project_path_tilde () =
  Test_helpers.with_env ~name:"HOME" ~value:(Some "/home/x") (fun () ->
      Alcotest.(check string)
        "~/foo" "/home/x/foo"
        (Project_path.to_string (Project_path.of_raw "~/foo"));
      Alcotest.(check string)
        "~" "/home/x"
        (Project_path.to_string (Project_path.of_raw "~")))

let test_project_path_env_subst () =
  Test_helpers.with_env ~name:"PCTL_TEST_FOO" ~value:(Some "bar") (fun () ->
      Test_helpers.with_env ~name:"PCTL_TEST_NOPE" ~value:None (fun () ->
          Alcotest.(check string)
            "/$FOO/baz" "/bar/baz"
            (Project_path.to_string
               (Project_path.of_raw "/$PCTL_TEST_FOO/baz"));
          Alcotest.(check string)
            "${FOO} braced" "/bar/baz"
            (Project_path.to_string
               (Project_path.of_raw "/${PCTL_TEST_FOO}/baz"));
          (* Missing var expands to empty → "/" + "/x" → "//x" →
           * normalize → "/x". *)
          Alcotest.(check string)
            "/$NOPE/x" "/x"
            (Project_path.to_string
               (Project_path.of_raw "/$PCTL_TEST_NOPE/x"))))

let test_project_path_normalize () =
  Alcotest.(check string)
    "dotdot" "/a/c"
    (Project_path.to_string (Project_path.of_raw "/a/b/../c"));
  Alcotest.(check string)
    "dot" "/a"
    (Project_path.to_string (Project_path.of_raw "/./a"));
  Alcotest.(check string)
    "double slash" "/a/b"
    (Project_path.to_string (Project_path.of_raw "/a//b"))

let test_project_path_relative () =
  Test_helpers.with_tmpdir (fun cwd ->
      let got = Project_path.to_string (Project_path.of_raw "sub") in
      Alcotest.(check string)
        "relative resolves vs cwd"
        (Filename.concat cwd "sub")
        got)

(* Reuse the same [arb_path] shape as test_identity — absolute, 1..4
 * segments, ASCII-ish. *)
let arb_path =
  let open QCheck in
  let char_gen =
    Gen.oneof_weighted
      [
        (10, Gen.char_range 'a' 'z');
        (10, Gen.char_range 'A' 'Z');
        (5, Gen.char_range '0' '9');
        (2, Gen.return '_');
        (2, Gen.return '-');
      ]
  in
  let segment = Gen.string_size ~gen:char_gen (Gen.int_range 1 10) in
  let path_gen =
    let open Gen in
    let* n = int_range 1 4 in
    let* segs = list_size (return n) segment in
    return ("/" ^ String.concat "/" segs)
  in
  make ~print:(fun s -> s) path_gen

let prop_project_path_is_abs =
  QCheck.Test.make ~count:200 ~name:"Project_path.of_raw result is absolute"
    arb_path (fun p ->
      Fpath.is_abs (Project_path.to_fpath (Project_path.of_raw p)))

let test_project_path_home_unset_raises () =
  Test_helpers.with_env ~name:"HOME" ~value:None (fun () ->
      Alcotest.check_raises "~/x with HOME unset"
        (Pctl_error
           (Identity_invalid { path = "~/x"; reason = "HOME not set" }))
        (fun () -> ignore (Project_path.of_raw "~/x")))

(* Unit_filename tests — smart ctors produce canonical leaves by
   construction; of_string_* rejects '/' and empty strings. *)

let test_unit_filename_slice () =
  let id = Project_id.of_string_exn "pctl_736e4605" in
  Alcotest.(check string)
    "slice leaf" "pctl-pctl_736e4605.slice"
    (Unit_filename.to_string (Unit_filename.slice ~id))

let test_unit_filename_service () =
  let id = Project_id.of_string_exn "pctl_736e4605" in
  Alcotest.(check string)
    "service leaf" "pctl-pctl_736e4605-web.service"
    (Unit_filename.to_string (Unit_filename.service ~id ~service:"web"))

let test_unit_filename_of_string_ok () =
  let s = "pctl-foo.slice" in
  Alcotest.(check string)
    "round-trip" s
    (Unit_filename.to_string (Unit_filename.of_string_exn s))

let test_unit_filename_of_string_slash_raises () =
  Alcotest.check_raises "slash raises"
    (Pctl_error
       (Identity_invalid
          { path = "path/with/slash"; reason = "unit filename contains '/'" }))
    (fun () -> ignore (Unit_filename.of_string_exn "path/with/slash"))

let test_unit_filename_of_string_empty_raises () =
  Alcotest.check_raises "empty raises"
    (Pctl_error
       (Identity_invalid { path = ""; reason = "empty unit filename" }))
    (fun () -> ignore (Unit_filename.of_string_exn ""))

let test_unit_filename_of_string_opt_slash () =
  Alcotest.(check bool)
    "slash → None" true
    (Option.is_none (Unit_filename.of_string_opt "with/slash"))

let test_result_row_to_json () =
  (* Byte-level golden: tuor's collect-pctl-artifacts.nu parses the
   * fields by name and never compares state/kind against specific
   * strings, so we emit snake_case bare strings. Shape:
   *   {"name":..., "state":..., "elapsed":..., "kind":...}
   * with state in {active,failed,inactive,probe_failed,timed_out} and
   * kind in {probe,unit_state}. *)
  let r =
    {
      name = "pg";
      state = `Probe_failed;
      elapsed = 123456789L;
      kind = `Unit_state;
    }
  in
  let s = Yojson.Safe.to_string (result_row_to_yojson r) in
  Alcotest.(check string)
    "probe_failed unit_state JSON"
    "{\"name\":\"pg\",\"state\":\"probe_failed\",\"elapsed\":123456789,\"kind\":\"unit_state\"}"
    s;
  let r2 =
    { name = "test-a"; state = `Active; elapsed = 42L; kind = `Probe }
  in
  Alcotest.(check string)
    "active probe JSON"
    "{\"name\":\"test-a\",\"state\":\"active\",\"elapsed\":42,\"kind\":\"probe\"}"
    (Yojson.Safe.to_string (result_row_to_yojson r2))

let test_result_row_of_json () =
  let round_trip r =
    match result_row_of_yojson (result_row_to_yojson r) with
    | Ok r' ->
        Alcotest.(check string) "name" r.name r'.name;
        Alcotest.(check bool) "state" true (r.state = r'.state);
        Alcotest.(check int64) "elapsed" r.elapsed r'.elapsed;
        Alcotest.(check bool) "kind" true (r.kind = r'.kind)
    | Error e -> Alcotest.fail ("parse failed: " ^ e)
  in
  round_trip
    { name = "pg"; state = `Active; elapsed = 1_000_000_000L; kind = `Probe };
  round_trip
    {
      name = "server";
      state = `Timed_out;
      elapsed = 0L;
      kind = `Unit_state;
    };
  (match result_row_of_yojson (`String "bad") with
  | Ok _ -> Alcotest.fail "should not parse string"
  | Error _ -> ());
  match
    result_row_of_yojson
      (`Assoc
         [
           ("name", `String "x");
           ("state", `String "bogus");
           ("elapsed", `Int 1);
           ("kind", `String "probe");
         ])
  with
  | Ok _ -> Alcotest.fail "should reject unknown state"
  | Error _ -> ()

let test_error_rendering () =
  let msgs =
    [
      ( Spec_not_found { path = "/no" },
        "spec not found: /no" );
      ( Spec_parse { path = "/a"; msg = "bad" },
        "spec parse error (/a): bad" );
      ( Spec_unknown_version 42,
        "spec version 42 is not supported by this pctl" );
      ( Nix_build_failed { expr = ".#x"; exit_code = 1; stderr = "oops" },
        "nix build '.#x' failed with exit 1:\noops" );
      ( Install_failed { path = "/dst"; reason = "eacces" },
        "install failed for /dst: eacces" );
      ( Uninstall_failed { path = "/dst"; reason = "eacces" },
        "uninstall failed for /dst: eacces" );
      ( Bus_connect_failed { msg = "no socket" },
        "sd-bus connect failed: no socket" );
      (* [op] is a D-Bus method name, which is what the Dbus adapter
         raises — see lib/systemctl/dbus.ml. The rendering is odd for it
         ("systemctl StartUnit …", tracked by pctl-19n); a fabricated
         lowercase verb here would hide that rather than fix it. *)
      ( Unit_op_failed
          {
            op = "StartUnit";
            unit_ = "x.service";
            error_name = None;
            reply = "nope";
          },
        "systemctl StartUnit x.service failed: nope" );
      ( Probe_timeout { service = "pg"; timeout_ms = 1000 },
        "probe for service pg timed out after 1000 ms" );
      ( Identity_invalid { path = "/p"; reason = "bad" },
        "invalid identity for '/p': bad" );
      ( Registry_io { id = "proj_1"; reason = "eio" },
        "registry I/O failure for project proj_1: eio" );
    ]
  in
  List.iter
    (fun (e, expected) ->
      Alcotest.(check string) expected expected (render_error e))
    msgs

let test_error_exit_codes () =
  let pairs =
    [
      (Spec_not_found { path = "" }, 2);
      (Spec_parse { path = ""; msg = "" }, 2);
      (Spec_unknown_version 0, 2);
      (Identity_invalid { path = ""; reason = "" }, 2);
      (Nix_build_failed { expr = ""; exit_code = 0; stderr = "" }, 3);
      (Install_failed { path = ""; reason = "" }, 4);
      (Uninstall_failed { path = ""; reason = "" }, 4);
      (Registry_io { id = ""; reason = "" }, 4);
      (Bus_connect_failed { msg = "" }, 5);
      ( Unit_op_failed { op = ""; unit_ = ""; error_name = None; reply = "" },
        5 );
      (Probe_timeout { service = ""; timeout_ms = 0 }, 6);
    ]
  in
  List.iter
    (fun (e, code) ->
      Alcotest.(check int)
        ("exit code for " ^ render_error e)
        code (error_exit_code e))
    pairs

let () =
  let open Alcotest in
  run "pctl schema"
    [
      ( "schema",
        [
          test_case "action strings + symbols" `Quick test_action_strings;
          test_case "state strings" `Quick test_state_strings;
          test_case "kind strings" `Quick test_kind_strings;
          test_case "class strings" `Quick test_class_strings;
          test_case "project_id smart ctor" `Quick test_project_id_smart_ctor;
          test_case "host smart ctor" `Quick test_host_smart_ctor;
          test_case "project_path idempotent" `Quick
            test_project_path_idempotent;
          test_case "project_path tilde expansion" `Quick
            test_project_path_tilde;
          test_case "project_path env-var substitution" `Quick
            test_project_path_env_subst;
          test_case "project_path normalize" `Quick test_project_path_normalize;
          test_case "project_path relative vs cwd" `Quick
            test_project_path_relative;
          test_case "project_path HOME unset raises" `Quick
            test_project_path_home_unset_raises;
          test_case "unit_filename slice leaf" `Quick test_unit_filename_slice;
          test_case "unit_filename service leaf" `Quick
            test_unit_filename_service;
          test_case "unit_filename of_string_exn round-trip" `Quick
            test_unit_filename_of_string_ok;
          test_case "unit_filename of_string_exn slash raises" `Quick
            test_unit_filename_of_string_slash_raises;
          test_case "unit_filename of_string_exn empty raises" `Quick
            test_unit_filename_of_string_empty_raises;
          test_case "unit_filename of_string_opt slash → None" `Quick
            test_unit_filename_of_string_opt_slash;
          test_case "result_row → JSON golden" `Quick test_result_row_to_json;
          test_case "result_row round-trip" `Quick test_result_row_of_json;
          test_case "error rendering" `Quick test_error_rendering;
          test_case "error exit codes" `Quick test_error_exit_codes;
        ]
        @ List.map QCheck_alcotest.to_alcotest [ prop_project_path_is_abs ] );
    ]
