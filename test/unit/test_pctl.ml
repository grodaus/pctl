(* Phase 1 pure-core test suite.
 *
 * Layout:
 *   - test_schema     — ADTs, opaque types, yojson round-trip, error rendering
 *   - test_identity   — derive, allocate, fixture parity with the Nushell oracle
 *   - test_render     — substitute, service/slice golden files
 *   - test_manifest   — diff correctness and qcheck properties
 *
 * Runs under alcotest; qcheck properties are wrapped via qcheck-alcotest.
 *
 * Hermetic: no filesystem writes, fixtures are read-only via Sys.getenv
 * "DUNE_SOURCEROOT" resolution (alcotest gets cwd = source dir under dune
 * test, so a relative path under test/unit/fixtures works). *)

open Schema

(* The `identity` library wraps its two modules under Identity.*.
 * Pull Host_alloc up so tests match the task-brief naming (Host.allocate). *)
module Host_alloc = Identity.Host_alloc
module Manifest = State.Manifest

(* ------------------------------------------------------------------ *)
(* Test helpers                                                         *)
(* ------------------------------------------------------------------ *)

let read_file p =
  let ic = open_in p in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let fixture_dir = "fixtures/render"
let fixture p = Filename.concat fixture_dir p
let spec_fixture name = Filename.concat "fixtures/spec" (name ^ ".json")

(* Local substring predicate — alcotest has no string-contains check and
 * we don't want to depend on astring just for this. Used by the spec
 * error-message assertions to verify the offending field name appears
 * in the error text. *)
module Astring_contains = struct
  let substring (haystack : string) (needle : string) : bool =
    let hl = String.length haystack in
    let nl = String.length needle in
    if nl = 0 then true
    else if nl > hl then false
    else
      let rec loop i =
        if i > hl - nl then false
        else if String.sub haystack i nl = needle then true
        else loop (i + 1)
      in
      loop 0
end

(* Write a string to a temp file and return its path. Used by the spec-loader
 * tests that need to exercise hand-crafted malformed input (the good-path
 * fixtures come from nix build; the bad-path fixtures are forged locally to
 * target specific error paths). *)
let write_temp_file ~prefix ~contents =
  let path = Filename.temp_file prefix ".json" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  path

(* ================================================================ *)
(* SCHEMA TESTS                                                      *)
(* ================================================================ *)

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
  let ok s = Alcotest.(check bool) s true (Option.is_some (Project_id.of_string_opt s)) in
  let bad s = Alcotest.(check bool) s true (Option.is_none (Project_id.of_string_opt s)) in
  ok "my_project_12345678";
  ok "pctl_736e4605";
  bad "";
  bad "has/slash";
  bad "has\x01bad";
  (* Raises on of_string_exn *)
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
  let j = result_row_to_yojson r in
  let s = Yojson.Safe.to_string j in
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
  (* Malformed input. *)
  (match result_row_of_yojson (`String "bad") with
  | Ok _ -> Alcotest.fail "should not parse string"
  | Error _ -> ());
  (match
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
  | Error _ -> ())

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
      ( Bus_connect_failed { msg = "no socket" },
        "sd-bus connect failed: no socket" );
      ( Unit_op_failed { op = "start"; unit_ = "x.service"; reply = "nope" },
        "systemctl start x.service failed: nope" );
      ( Probe_exec_failed { service = "pg"; msg = "enoent" },
        "probe for service pg failed to exec: enoent" );
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
      (Registry_io { id = ""; reason = "" }, 4);
      (Bus_connect_failed { msg = "" }, 5);
      (Unit_op_failed { op = ""; unit_ = ""; reply = "" }, 5);
      (Probe_exec_failed { service = ""; msg = "" }, 6);
      (Probe_timeout { service = ""; timeout_ms = 0 }, 6);
    ]
  in
  List.iter
    (fun (e, code) ->
      Alcotest.(check int)
        ("exit code for " ^ render_error e)
        code (error_exit_code e))
    pairs

(* ================================================================ *)
(* IDENTITY TESTS                                                    *)
(* ================================================================ *)

(* Fixture parity anchors — computed once from the prior Nushell
 * identity module (`derive-id <path>` and `allocate-host`) and hardcoded
 * here. If the OCaml port drifts from the Nushell semantics, THESE fail
 * first — treat a fail as a port bug, not a test bug. Regenerate only
 * with explicit user approval. *)
let fixture_ids =
  [
    ("/tmp/my-project", "my_project_52089b5d", "127.0.0.84");
    ("/tmp/other-project", "other_project_1e0d9858", "127.0.0.129");
    ("/tmp/my project!", "my_project_86fabda8", "127.0.0.136");
    ("/tmp/UPPER", "upper_01521a1f", "127.0.0.68");
    ("/tmp/my-cool-repo", "my_cool_repo_36d2d7b4", "127.0.0.247");
    ("/home/manveru/ghq/github.com/grodaus/pctl", "pctl_736e4605", "127.0.0.104");
  ]

let test_derive_fixtures () =
  List.iter
    (fun (path, expected_id, _host) ->
      let got = Project_id.to_string (Identity.derive ~path) in
      Alcotest.(check string) ("derive " ^ path) expected_id got)
    fixture_ids

let test_allocate_fixtures () =
  List.iter
    (fun (path, _id, expected_host) ->
      let id = Identity.derive ~path in
      let got = Host.to_string (Host_alloc.allocate ~id ~taken:[]) in
      Alcotest.(check string) ("host " ^ path) expected_host got)
    fixture_ids

let test_sanitize_basename_cases () =
  let check raw expected =
    Alcotest.(check string) raw expected (Identity.sanitize_basename raw)
  in
  check "my-project" "my_project";
  check "my project!" "my_project";
  check "UPPER" "upper";
  check "___foo___" "foo";
  check "my-cool-repo" "my_cool_repo";
  check "!!!" "project";
  check "" "project";
  check "a" "a"

let test_derive_determinism () =
  let a = Identity.derive ~path:"/tmp/repeated-check" in
  let b = Identity.derive ~path:"/tmp/repeated-check" in
  Alcotest.(check string)
    "same path → same id"
    (Project_id.to_string a)
    (Project_id.to_string b)

let test_allocate_skips_taken () =
  let id = Identity.derive ~path:"/tmp/my-project" in
  let nat = Host_alloc.allocate ~id ~taken:[] in
  let bumped = Host_alloc.allocate ~id ~taken:[ nat ] in
  Alcotest.(check bool)
    "bumped differs"
    true
    (not (Host.equal nat bumped));
  (* The bumped slot is still in the valid 127.0.0.2..254 range. *)
  Alcotest.(check bool)
    "bumped is still a valid host"
    true
    (Option.is_some (Host.of_string_opt (Host.to_string bumped)))

let test_allocate_exhausted () =
  let id = Identity.derive ~path:"/tmp/my-project" in
  let all =
    List.init 253 (fun i -> Host.of_string_exn (Printf.sprintf "127.0.0.%d" (i + 2)))
  in
  Alcotest.check_raises "no free slot"
    (Pctl_error
       (Identity_invalid
          {
            path = Project_id.to_string id;
            reason =
              Printf.sprintf
                "allocate-host: no free slot in 127.0.0.2..254 for id '%s'"
                (Project_id.to_string id);
          }))
    (fun () -> ignore (Host_alloc.allocate ~id ~taken:all))

(* QCheck properties. *)

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
        (1, Gen.return ' ');
        (1, Gen.return '!');
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

let prop_derive_deterministic =
  QCheck.Test.make ~count:200 ~name:"derive: same path → same id"
    arb_path (fun p ->
      let a = Identity.derive ~path:p in
      let b = Identity.derive ~path:p in
      Project_id.equal a b)

let prop_allocate_deterministic =
  QCheck.Test.make ~count:200 ~name:"allocate: same id, empty taken → same host"
    arb_path (fun p ->
      let id = Identity.derive ~path:p in
      let a = Host_alloc.allocate ~id ~taken:[] in
      let b = Host_alloc.allocate ~id ~taken:[] in
      Host.equal a b)

let prop_allocate_in_range =
  QCheck.Test.make ~count:200 ~name:"allocate: result parses as valid host"
    arb_path (fun p ->
      let id = Identity.derive ~path:p in
      let h = Host_alloc.allocate ~id ~taken:[] in
      Option.is_some (Host.of_string_opt (Host.to_string h)))

(* ================================================================ *)
(* RENDER TESTS                                                      *)
(* ================================================================ *)

let id_demo = Project_id.of_string_exn "demo_abc12345"

let test_substitute_basic () =
  let s = "hello @@PROJECT@@ at @@PROJECT_PATH@@" in
  let got = Render.substitute s ~id:id_demo ~project_path:"/home/me" in
  Alcotest.(check string)
    "subst both"
    "hello demo_abc12345 at /home/me"
    got

let test_substitute_no_placeholder () =
  let s = "nothing to replace here" in
  let got = Render.substitute s ~id:id_demo ~project_path:"/x" in
  Alcotest.(check string) "unchanged" s got

let test_substitute_idempotent () =
  let s = "path=@@PROJECT_PATH@@ id=@@PROJECT@@" in
  let once = Render.substitute s ~id:id_demo ~project_path:"/p" in
  let twice = Render.substitute once ~id:id_demo ~project_path:"/p" in
  Alcotest.(check string) "idempotent" once twice

(* qcheck properties *)

(* String.contains only handles single chars; needle-search helper. *)
let contains_substring s needle =
  let nlen = String.length needle in
  let slen = String.length s in
  if nlen = 0 then true
  else if nlen > slen then false
  else
    let rec loop i =
      if i > slen - nlen then false
      else if String.sub s i nlen = needle then true
      else loop (i + 1)
    in
    loop 0

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
      (* Property only holds when the generated id/path don't themselves
       * contain the placeholder — the arbitrary above generates only
       * lowercase ASCII path segments, so this is vacuously safe, but we
       * gate defensively in case arb_safe_id ever broadens. *)
      if
        (* Defensive gate: if the substituted id/path itself contains a
         * placeholder, a second pass would re-expand it — property fails.
         * arb_safe_id / arb_safe_path today generate only [a-z0-9/] so
         * neither token can appear, but we check all four crossings
         * explicitly so widening the generators doesn't silently turn the
         * property flaky. *)
        contains_substring id_s "@@PROJECT@@"
        || contains_substring id_s "@@PROJECT_PATH@@"
        || contains_substring path "@@PROJECT@@"
        || contains_substring path "@@PROJECT_PATH@@"
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
  let expected = read_file (fixture "simple_service.expected") in
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
  let expected = read_file (fixture "bindpaths_service.expected") in
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
  let expected = read_file (fixture "slice.expected") in
  Alcotest.(check string) "slice golden" expected got

(* ================================================================ *)
(* MANIFEST TESTS                                                    *)
(* ================================================================ *)

let pp_action = function
  | Added -> "added"
  | Changed -> "changed"
  | Unchanged -> "unchanged"
  | Removed -> "removed"

let action_testable =
  Alcotest.testable (fun fmt a -> Format.pp_print_string fmt (pp_action a)) ( = )

let test_diff_unchanged () =
  let m = [ ("a.service", "h1") ] in
  let rows = Manifest.diff ~before:m ~after:m in
  Alcotest.(check int) "one row" 1 (List.length rows);
  let r = List.hd rows in
  Alcotest.check action_testable "unchanged" Unchanged r.action;
  Alcotest.(check string) "unit" "a.service" r.unit_

let test_diff_added () =
  let rows = Manifest.diff ~before:[] ~after:[ ("a", "h1") ] in
  let r = List.hd rows in
  Alcotest.check action_testable "added" Added r.action;
  Alcotest.(check (option string)) "new_hash" (Some "h1") r.new_hash;
  Alcotest.(check (option string)) "no old" None r.old_hash

let test_diff_removed () =
  let rows = Manifest.diff ~before:[ ("a", "h1") ] ~after:[] in
  let r = List.hd rows in
  Alcotest.check action_testable "removed" Removed r.action;
  Alcotest.(check (option string)) "old_hash" (Some "h1") r.old_hash

let test_diff_changed () =
  let rows = Manifest.diff ~before:[ ("a", "h1") ] ~after:[ ("a", "h2") ] in
  let r = List.hd rows in
  Alcotest.check action_testable "changed" Changed r.action;
  Alcotest.(check (option string)) "old" (Some "h1") r.old_hash;
  Alcotest.(check (option string)) "new" (Some "h2") r.new_hash

let test_diff_sort () =
  let before = [ ("a", "1"); ("b", "2"); ("c", "3") ] in
  let after = [ ("b", "2"); ("c", "9"); ("d", "4") ] in
  let rows = Manifest.diff ~before ~after in
  let names = List.map (fun r -> r.unit_) rows in
  let actions = List.map (fun r -> pp_action r.action) rows in
  Alcotest.(check (list string)) "sorted" [ "a"; "b"; "c"; "d" ] names;
  Alcotest.(check (list string))
    "actions"
    [ "removed"; "unchanged"; "changed"; "added" ]
    actions

let test_diff_summary () =
  let before = [ ("a", "1"); ("b", "2"); ("c", "3") ] in
  let after = [ ("b", "2"); ("c", "9"); ("d", "4") ] in
  let rows = Manifest.diff ~before ~after in
  Alcotest.(check string) "summary" "+1 ~1 =1 -1" (Manifest.summary rows)

(* QCheck properties *)

let arb_manifest =
  let open QCheck in
  let kv =
    pair
      (Gen.string_size ~gen:(Gen.char_range 'a' 'z') (Gen.int_range 1 6)
      |> QCheck.make ~print:(fun s -> s))
      (string_size (Gen.int_range 1 6))
  in
  list_size (Gen.int_range 0 10) kv

let canonicalize (m : manifest) : manifest =
  (* De-dup + sort for compare. *)
  let map =
    List.fold_left
      (fun acc (k, v) -> StringMap.add k v acc)
      StringMap.empty m
  in
  StringMap.bindings map

let prop_diff_symmetry =
  QCheck.Test.make ~count:200 ~name:"diff symmetry"
    (QCheck.pair arb_manifest arb_manifest)
    (fun (a, b) ->
      let a = canonicalize a and b = canonicalize b in
      let fwd = Manifest.diff ~before:a ~after:b in
      let rev = Manifest.diff ~before:b ~after:a in
      let count_fwd act = List.length (List.filter (fun r -> r.action = act) fwd) in
      let count_rev act = List.length (List.filter (fun r -> r.action = act) rev) in
      count_fwd Added = count_rev Removed
      && count_fwd Removed = count_rev Added
      && count_fwd Unchanged = count_rev Unchanged
      && count_fwd Changed = count_rev Changed)

let prop_diff_empty_before =
  QCheck.Test.make ~count:200 ~name:"empty before → every row Added"
    arb_manifest
    (fun after ->
      let after = canonicalize after in
      let rows = Manifest.diff ~before:[] ~after in
      List.length rows = List.length after
      && List.for_all (fun r -> r.action = Added) rows)

let prop_diff_same =
  QCheck.Test.make ~count:200 ~name:"same → every row Unchanged"
    arb_manifest
    (fun m ->
      let m = canonicalize m in
      let rows = Manifest.diff ~before:m ~after:m in
      List.length rows = List.length m
      && List.for_all (fun r -> r.action = Unchanged) rows)

(* ================================================================ *)
(* SPEC TESTS                                                        *)
(* ================================================================ *)

(* These tests exercise Spec.load against the real spec.json files that
 * nix/lib/mkProject.nix emits. Regenerate via nix build (see
 * nix/fixtures.nix) if you change the emitter. *)

let test_spec_load_single () =
  let spec = Spec.load ~path:(spec_fixture "single") in
  Alcotest.(check int) "version" 1 spec.version;
  Alcotest.(check string)
    "slice unit_filename"
    "pctl-@@PROJECT@@.slice" spec.slice.unit_filename;
  Alcotest.(check int) "service count" 1 (StringMap.cardinal spec.services);
  let pg = StringMap.find "pg" spec.services in
  Alcotest.(check string) "name" "pg" pg.name;
  Alcotest.(check bool) "kind" true (pg.kind = Simple);
  Alcotest.(check (list string)) "depends_on" [] pg.depends_on;
  Alcotest.(check bool) "workspace.cwd" false pg.workspace.cwd;
  Alcotest.(check bool) "workspace.writable" false pg.workspace.writable;
  Alcotest.(check bool) "probe is None" true (pg.probe = None);
  Alcotest.(check string)
    "unit_filename" "pctl-@@PROJECT@@-pg.service" pg.unit_filename;
  (* service_config keys come from sandbox-defaults + command->ExecStart +
   * the forced Type= entry. Assert the must-haves without locking in
   * every sandbox key (that would couple the test to nix/lib/sandbox-defaults.nix). *)
  let sc = pg.service_config in
  Alcotest.(check (option string))
    "ExecStart" (Some "/bin/true") (List.assoc_opt "ExecStart" sc);
  Alcotest.(check (option string))
    "Type" (Some "simple") (List.assoc_opt "Type" sc)

let test_spec_load_multi_depends_on () =
  let spec = Spec.load ~path:(spec_fixture "multi") in
  Alcotest.(check int) "service count" 3 (StringMap.cardinal spec.services);
  let server = StringMap.find "server" spec.services in
  Alcotest.(check (list string))
    "server depends_on" [ "pg"; "migrate" ] server.depends_on;
  let pg = StringMap.find "pg" spec.services in
  Alcotest.(check (list string)) "pg depends_on" [ "migrate" ] pg.depends_on;
  let migrate = StringMap.find "migrate" spec.services in
  Alcotest.(check (list string)) "migrate depends_on" [] migrate.depends_on

let test_spec_load_probe () =
  let spec = Spec.load ~path:(spec_fixture "probe") in
  let pg = StringMap.find "pg" spec.services in
  match pg.probe with
  | None -> Alcotest.fail "expected probe to be present"
  | Some p ->
      Alcotest.(check (list string)) "exec" [ "/bin/true" ] p.exec;
      Alcotest.(check int) "period_seconds" 2 p.period_seconds;
      Alcotest.(check int) "timeout_seconds" 60 p.timeout_seconds

let test_spec_load_workspace () =
  let spec = Spec.load ~path:(spec_fixture "workspace") in
  let worker = StringMap.find "worker" spec.services in
  Alcotest.(check bool) "cwd" true worker.workspace.cwd;
  Alcotest.(check bool) "writable" true worker.workspace.writable;
  (* And the workspace fragments must have landed in service_config —
   * OCaml relies on mkProject having folded them in. *)
  let sc = worker.service_config in
  Alcotest.(check (option string))
    "WorkingDirectory" (Some "@@PROJECT_PATH@@")
    (List.assoc_opt "WorkingDirectory" sc);
  Alcotest.(check (option string))
    "BindPaths" (Some "@@PROJECT_PATH@@")
    (List.assoc_opt "BindPaths" sc);
  Alcotest.(check (option string))
    "ProtectHome" (Some "tmpfs")
    (List.assoc_opt "ProtectHome" sc)

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

let test_spec_load_missing_file () =
  check_raises_pctl ~name:"missing file"
    ~predicate:(function Spec_not_found _ -> true | _ -> false) (fun () ->
      Spec.load ~path:"/nonexistent/pctl-spec.json")

let test_spec_load_parse_error () =
  let path = write_temp_file ~prefix:"pctl-bad-" ~contents:"{not json" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"bad JSON"
        ~predicate:(function Spec_parse _ -> true | _ -> false) (fun () ->
          Spec.load ~path))

let test_spec_load_unknown_version () =
  let path =
    write_temp_file ~prefix:"pctl-v99-"
      ~contents:
        "{\"version\": 99, \"slice\": {\"unit_filename\": \"s.slice\"}, \
         \"services\": {}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"unknown version"
        ~predicate:(function Spec_unknown_version 99 -> true | _ -> false)
        (fun () -> Spec.load ~path))

let test_spec_load_missing_version () =
  let path =
    write_temp_file ~prefix:"pctl-novers-"
      ~contents:
        "{\"slice\": {\"unit_filename\": \"s.slice\"}, \"services\": {}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing version"
        ~predicate:(function Spec_parse _ -> true | _ -> false) (fun () ->
          Spec.load ~path))

let test_spec_load_missing_slice () =
  let path =
    write_temp_file ~prefix:"pctl-noslice-"
      ~contents:"{\"version\": 1, \"services\": {}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing slice"
        ~predicate:(function Spec_parse _ -> true | _ -> false) (fun () ->
          Spec.load ~path))

let test_spec_load_missing_services () =
  let path =
    write_temp_file ~prefix:"pctl-nosvc-"
      ~contents:
        "{\"version\": 1, \"slice\": {\"unit_filename\": \"s.slice\"}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing services"
        ~predicate:(function Spec_parse _ -> true | _ -> false) (fun () ->
          Spec.load ~path))

let test_spec_load_missing_kind () =
  let path =
    write_temp_file ~prefix:"pctl-nokind-"
      ~contents:
        "{\"version\": 1, \"slice\": {\"unit_filename\": \"s.slice\"}, \
         \"services\": {\"pg\": {\"unit_filename\": \"pg.service\", \
         \"service_config\": {}}}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing kind"
        ~predicate:(function
          | Spec_parse { msg; _ } ->
              (* must name the offending field *)
              Astring_contains.substring msg "kind"
          | _ -> false)
        (fun () -> Spec.load ~path))

let test_spec_load_missing_unit_filename () =
  let path =
    write_temp_file ~prefix:"pctl-nouf-"
      ~contents:
        "{\"version\": 1, \"slice\": {\"unit_filename\": \"s.slice\"}, \
         \"services\": {\"pg\": {\"kind\": \"simple\", \
         \"service_config\": {}}}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing unit_filename"
        ~predicate:(function
          | Spec_parse { msg; _ } ->
              Astring_contains.substring msg "unit_filename"
          | _ -> false)
        (fun () -> Spec.load ~path))

let test_spec_load_missing_service_config () =
  let path =
    write_temp_file ~prefix:"pctl-nosc-"
      ~contents:
        "{\"version\": 1, \"slice\": {\"unit_filename\": \"s.slice\"}, \
         \"services\": {\"pg\": {\"kind\": \"simple\", \
         \"unit_filename\": \"pg.service\"}}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"missing service_config"
        ~predicate:(function
          | Spec_parse { msg; _ } ->
              Astring_contains.substring msg "service_config"
          | _ -> false)
        (fun () -> Spec.load ~path))

let test_spec_load_bad_service_config_value () =
  (* service_config values must be strings; we flag the offending key. *)
  let path =
    write_temp_file ~prefix:"pctl-badsc-"
      ~contents:
        "{\"version\": 1, \"slice\": {\"unit_filename\": \"s.slice\"}, \
         \"services\": {\"pg\": {\"kind\": \"simple\", \
         \"unit_filename\": \"pg.service\", \
         \"service_config\": {\"ExecStart\": 42}}}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"non-string service_config value"
        ~predicate:(function
          | Spec_parse { msg; _ } ->
              Astring_contains.substring msg "ExecStart"
          | _ -> false)
        (fun () -> Spec.load ~path))

let test_spec_load_bad_kind () =
  let path =
    write_temp_file ~prefix:"pctl-badkind-"
      ~contents:
        "{\"version\": 1, \"slice\": {\"unit_filename\": \"s.slice\"}, \
         \"services\": {\"pg\": {\"kind\": \"zombie\", \
         \"unit_filename\": \"pg.service\", \"service_config\": {}}}}"
  in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () ->
      check_raises_pctl ~name:"unknown kind"
        ~predicate:(function
          | Spec_parse { msg; _ } -> Astring_contains.substring msg "zombie"
          | _ -> false)
        (fun () -> Spec.load ~path))

(* ================================================================ *)
(* Test runner                                                       *)
(* ================================================================ *)

let () =
  let open Alcotest in
  run "pctl phase1"
    [
      ( "schema",
        [
          test_case "action strings + symbols" `Quick test_action_strings;
          test_case "state strings" `Quick test_state_strings;
          test_case "kind strings" `Quick test_kind_strings;
          test_case "class strings" `Quick test_class_strings;
          test_case "project_id smart ctor" `Quick test_project_id_smart_ctor;
          test_case "host smart ctor" `Quick test_host_smart_ctor;
          test_case "result_row → JSON golden" `Quick test_result_row_to_json;
          test_case "result_row round-trip" `Quick test_result_row_of_json;
          test_case "error rendering" `Quick test_error_rendering;
          test_case "error exit codes" `Quick test_error_exit_codes;
        ] );
      ( "identity",
        [
          test_case "sanitize_basename cases" `Quick test_sanitize_basename_cases;
          test_case "derive fixture parity" `Quick test_derive_fixtures;
          test_case "allocate fixture parity" `Quick test_allocate_fixtures;
          test_case "derive determinism" `Quick test_derive_determinism;
          test_case "allocate skips taken" `Quick test_allocate_skips_taken;
          test_case "allocate exhausted raises" `Quick test_allocate_exhausted;
        ]
        @ List.map QCheck_alcotest.to_alcotest
            [
              prop_derive_deterministic;
              prop_allocate_deterministic;
              prop_allocate_in_range;
            ] );
      ( "render",
        [
          test_case "substitute basic" `Quick test_substitute_basic;
          test_case "substitute no placeholder" `Quick test_substitute_no_placeholder;
          test_case "substitute idempotent" `Quick test_substitute_idempotent;
          test_case "service golden (simple)" `Quick test_render_simple_service;
          test_case "service golden (bindpaths + user description)"
            `Quick test_render_service_with_bindpaths;
          test_case "slice golden" `Quick test_render_slice;
        ]
        @ List.map QCheck_alcotest.to_alcotest [ prop_substitute_idempotent ]
      );
      ( "manifest",
        [
          test_case "unchanged" `Quick test_diff_unchanged;
          test_case "added" `Quick test_diff_added;
          test_case "removed" `Quick test_diff_removed;
          test_case "changed" `Quick test_diff_changed;
          test_case "sorted with mixed actions" `Quick test_diff_sort;
          test_case "summary format" `Quick test_diff_summary;
        ]
        @ List.map QCheck_alcotest.to_alcotest
            [ prop_diff_symmetry; prop_diff_empty_before; prop_diff_same ] );
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
          test_case "missing version -> Spec_parse" `Quick
            test_spec_load_missing_version;
          test_case "missing slice -> Spec_parse" `Quick
            test_spec_load_missing_slice;
          test_case "missing services -> Spec_parse" `Quick
            test_spec_load_missing_services;
          test_case "missing kind -> Spec_parse" `Quick
            test_spec_load_missing_kind;
          test_case "missing unit_filename -> Spec_parse" `Quick
            test_spec_load_missing_unit_filename;
          test_case "missing service_config -> Spec_parse" `Quick
            test_spec_load_missing_service_config;
          test_case "non-string service_config value -> Spec_parse" `Quick
            test_spec_load_bad_service_config_value;
          test_case "unknown kind -> Spec_parse" `Quick
            test_spec_load_bad_kind;
        ] );
    ]
