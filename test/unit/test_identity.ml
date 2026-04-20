(* Identity — derive, allocate. *)

open Schema
module Host_alloc = Identity.Host_alloc

(* Determinism anchors. Absolute paths only (no tilde/env tokens): a
 * future change to [Project_path.of_raw]'s tilde/env semantics must
 * not change these ids, because the input bytes [derive] hashes are
 * the normalized absolute path. If one of these fails, the [derive]
 * algorithm changed — treat that as a break. *)
let fixture_ids =
  [
    ("/tmp/my-project", "my_project_52089b5d", "127.0.0.84");
    ("/tmp/other-project", "other_project_1e0d9858", "127.0.0.129");
    ("/tmp/my project!", "my_project_86fabda8", "127.0.0.136");
    ("/tmp/UPPER", "upper_01521a1f", "127.0.0.68");
    ("/tmp/my-cool-repo", "my_cool_repo_36d2d7b4", "127.0.0.247");
    ( "/home/manveru/ghq/github.com/grodaus/pctl",
      "pctl_736e4605",
      "127.0.0.104" );
  ]

let test_derive_fixtures () =
  List.iter
    (fun (path, expected_id, _host) ->
      let got =
        Project_id.to_string
          (Identity.derive ~path:(Project_path.of_raw path))
      in
      Alcotest.(check string) ("derive " ^ path) expected_id got)
    fixture_ids

let test_allocate_fixtures () =
  List.iter
    (fun (path, _id, expected_host) ->
      let id = Identity.derive ~path:(Project_path.of_raw path) in
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
  let a =
    Identity.derive ~path:(Project_path.of_raw "/tmp/repeated-check")
  in
  let b =
    Identity.derive ~path:(Project_path.of_raw "/tmp/repeated-check")
  in
  Alcotest.(check string)
    "same path → same id"
    (Project_id.to_string a)
    (Project_id.to_string b)

(* Tilde expansion: [Project_path.of_raw] normalizes first, so a path
 * supplied as [~/foo] and the literal [$HOME/foo] must produce the
 * same project id. This is the behaviour the earlier Nushell-oracle
 * framing blocked. *)
let test_derive_tilde_equivalent_to_home () =
  let home =
    match Sys.getenv_opt "HOME" with
    | Some h -> h
    | None -> Alcotest.fail "HOME not set — test requires a set HOME"
  in
  let a = Identity.derive ~path:(Project_path.of_raw "~/pctl-test-derive") in
  let b =
    Identity.derive
      ~path:(Project_path.of_raw (home ^ "/pctl-test-derive"))
  in
  Alcotest.(check string)
    "~/foo ≡ $HOME/foo"
    (Project_id.to_string a)
    (Project_id.to_string b)

let test_allocate_skips_taken () =
  let id = Identity.derive ~path:(Project_path.of_raw "/tmp/my-project") in
  let nat = Host_alloc.allocate ~id ~taken:[] in
  let bumped = Host_alloc.allocate ~id ~taken:[ nat ] in
  Alcotest.(check bool) "bumped differs" true (not (Host.equal nat bumped));
  Alcotest.(check bool)
    "bumped is still a valid host"
    true
    (Option.is_some (Host.of_string_opt (Host.to_string bumped)))

let test_allocate_exhausted () =
  let id = Identity.derive ~path:(Project_path.of_raw "/tmp/my-project") in
  let all =
    List.init 253 (fun i ->
        Host.of_string_exn (Printf.sprintf "127.0.0.%d" (i + 2)))
  in
  Alcotest.check_raises "no free slot"
    (Pctl_error
       (Identity_invalid
          {
            path = Project_id.to_string id;
            reason =
              Printf.sprintf
                "Host.allocate: no free slot in 127.0.0.2..254 for id '%s'"
                (Project_id.to_string id);
          }))
    (fun () -> ignore (Host_alloc.allocate ~id ~taken:all))

(* QCheck properties — generator produces absolute paths with no tilde
 * or env-var tokens; the point is that [derive] is deterministic and
 * [allocate] always returns a parseable host for any id. *)

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
  QCheck.Test.make ~count:200 ~name:"derive: same path → same id" arb_path
    (fun p ->
      let a = Identity.derive ~path:(Project_path.of_raw p) in
      let b = Identity.derive ~path:(Project_path.of_raw p) in
      Project_id.equal a b)

let prop_allocate_deterministic =
  QCheck.Test.make ~count:200
    ~name:"allocate: same id, empty taken → same host" arb_path (fun p ->
      let id = Identity.derive ~path:(Project_path.of_raw p) in
      let a = Host_alloc.allocate ~id ~taken:[] in
      let b = Host_alloc.allocate ~id ~taken:[] in
      Host.equal a b)

let prop_allocate_in_range =
  QCheck.Test.make ~count:200 ~name:"allocate: result parses as valid host"
    arb_path (fun p ->
      let id = Identity.derive ~path:(Project_path.of_raw p) in
      let h = Host_alloc.allocate ~id ~taken:[] in
      Option.is_some (Host.of_string_opt (Host.to_string h)))

let () =
  let open Alcotest in
  run "pctl identity"
    [
      ( "identity",
        [
          test_case "sanitize_basename cases" `Quick test_sanitize_basename_cases;
          test_case "derive fixtures" `Quick test_derive_fixtures;
          test_case "allocate fixtures" `Quick test_allocate_fixtures;
          test_case "derive determinism" `Quick test_derive_determinism;
          test_case "derive ~/foo = $HOME/foo" `Quick
            test_derive_tilde_equivalent_to_home;
          test_case "allocate skips taken" `Quick test_allocate_skips_taken;
          test_case "allocate exhausted raises" `Quick test_allocate_exhausted;
        ]
        @ List.map QCheck_alcotest.to_alcotest
            [
              prop_derive_deterministic;
              prop_allocate_deterministic;
              prop_allocate_in_range;
            ] );
    ]
