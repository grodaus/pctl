(* In-process SQLite integration suite.
 *
 * Each test opens a fresh `sqlite3::memory:` connection via caqti-eio,
 * runs [Db.migrate] against it, then exercises one concern. No
 * filesystem writes; the only side effect is allocating an in-memory
 * DB per test.
 *
 * We can't use alcotest-eio (not in the nixpkgs pin), so every test
 * body runs under a local [eio_run] wrapper that spins up Eio_main and
 * opens a Switch. Caqti-eio requires both. *)

module Session = State.Session
module Db = State.Db
module Projects = State.Projects

(* In-memory caqti-eio connection factory. *)
let memory_uri = Uri.of_string "sqlite3::memory:"

(* Thread an Eio env + Switch through every test body. *)
let eio_run (f : sw:Eio.Switch.t -> stdenv:Caqti_eio.stdenv -> unit) : unit =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let stdenv : Caqti_eio.stdenv =
    object
      method net = (env#net :> [ `Generic ] Eio.Net.ty Eio.Std.r)
      method clock = (env#clock :> float Eio.Time.clock_ty Eio.Std.r)
      method mono_clock = (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
    end
  in
  f ~sw ~stdenv

let fresh_conn ~sw ~stdenv : Db.t =
  Db.connect_uri ~sw ~stdenv memory_uri

(* ----- migrations ------------------------------------------------ *)

let test_migrate_idempotent () =
  eio_run @@ fun ~sw ~stdenv ->
  let conn = fresh_conn ~sw ~stdenv in
  Db.migrate conn;
  (* Second run must be a no-op (no errors, version unchanged). *)
  Db.migrate conn;
  Alcotest.(check (option string))
    "schema_version" (Some "2")
    (Db.meta_get conn ~key:"schema_version");
  Alcotest.(check (option string))
    "last_boot_id starts empty" (Some "")
    (Db.meta_get conn ~key:"last_boot_id")

(* ----- projects CRUD -------------------------------------------- *)

let mk_project ?host ?started_at ?store_tree ?session_id ?spec_json id path :
    Projects.t =
  { id; path; host; started_at; store_tree; session_id; spec_json }

let test_projects_crud () =
  eio_run @@ fun ~sw ~stdenv ->
  let conn = fresh_conn ~sw ~stdenv in
  Db.migrate conn;
  let p1 =
    mk_project ~host:"127.0.0.42" ~started_at:"2026-04-19T00:00:00Z"
      ~store_tree:"/nix/store/xxx" ~session_id:"boot-a" "proj_1"
      "/tmp/proj_1"
  in
  let p2 = mk_project "proj_2" "/tmp/proj_2" in
  Projects.upsert conn p1;
  Projects.upsert conn p2;
  (match Projects.get_by_id conn ~id:"proj_1" with
  | None -> Alcotest.fail "proj_1 not found"
  | Some got ->
      Alcotest.(check string) "id" "proj_1" got.id;
      Alcotest.(check string) "path" "/tmp/proj_1" got.path;
      Alcotest.(check (option string))
        "host" (Some "127.0.0.42") got.host;
      Alcotest.(check (option string))
        "session_id" (Some "boot-a") got.session_id);
  (* Update (same id) overwrites host and other scoped columns. *)
  let p1' = { p1 with host = Some "127.0.0.99"; session_id = Some "boot-b" } in
  Projects.upsert conn p1';
  (match Projects.get_by_id conn ~id:"proj_1" with
  | None -> Alcotest.fail "proj_1 vanished after upsert"
  | Some got ->
      Alcotest.(check (option string))
        "host after update" (Some "127.0.0.99") got.host;
      Alcotest.(check (option string))
        "session after update" (Some "boot-b") got.session_id);
  (* get_by_path *)
  (match Projects.get_by_path conn ~path:"/tmp/proj_2" with
  | None -> Alcotest.fail "proj_2 not found by path"
  | Some got -> Alcotest.(check string) "id by path" "proj_2" got.id);
  (* all returns both, ordered by id *)
  let xs = Projects.all conn in
  Alcotest.(check (list string))
    "ids" [ "proj_1"; "proj_2" ]
    (List.map (fun (p : Projects.t) -> p.id) xs);
  (* delete by id *)
  Projects.delete_by_id conn ~id:"proj_1";
  Alcotest.(check bool)
    "proj_1 gone" true
    (Projects.get_by_id conn ~id:"proj_1" = None)

(* ----- manifest replacement ------------------------------------- *)

let test_manifest_replace () =
  eio_run @@ fun ~sw ~stdenv ->
  let conn = fresh_conn ~sw ~stdenv in
  Db.migrate conn;
  Projects.upsert conn (mk_project "proj_1" "/tmp/proj_1");
  let first : Schema.manifest =
    [ ("a.service", "h_a1"); ("b.service", "h_b1") ]
  in
  Projects.replace_manifest conn ~project_id:"proj_1" ~rows:first;
  let got = Projects.load_manifest conn ~project_id:"proj_1" in
  Alcotest.(check (list (pair string string)))
    "first manifest" first got;
  let second : Schema.manifest =
    [ ("b.service", "h_b2"); ("c.service", "h_c1") ]
  in
  Projects.replace_manifest conn ~project_id:"proj_1" ~rows:second;
  let got2 = Projects.load_manifest conn ~project_id:"proj_1" in
  Alcotest.(check (list (pair string string)))
    "second manifest (replaces, doesn't merge)"
    second got2

(* ----- session reset ------------------------------------------- *)

let test_session_reset_wipes_stale () =
  eio_run @@ fun ~sw ~stdenv ->
  let conn = fresh_conn ~sw ~stdenv in
  Db.migrate conn;
  Projects.upsert conn
    (mk_project ~host:"127.0.0.42" ~started_at:"now" ~store_tree:"/nix/store/x"
       ~session_id:"boot-a" "proj_1" "/tmp/proj_1");
  Session.reset_with_boot_id conn ~boot_id:"boot-b";
  (match Projects.get_by_id conn ~id:"proj_1" with
  | None -> Alcotest.fail "proj_1 vanished (should be reset, not deleted)"
  | Some got ->
      Alcotest.(check (option string)) "host NULL" None got.host;
      Alcotest.(check (option string)) "started_at NULL" None got.started_at;
      Alcotest.(check (option string)) "store_tree NULL" None got.store_tree;
      Alcotest.(check (option string)) "session_id NULL" None got.session_id);
  Alcotest.(check (option string))
    "meta last_boot_id" (Some "boot-b")
    (Db.meta_get conn ~key:"last_boot_id")

let test_session_reset_noop_same_boot () =
  eio_run @@ fun ~sw ~stdenv ->
  let conn = fresh_conn ~sw ~stdenv in
  Db.migrate conn;
  let p =
    mk_project ~host:"127.0.0.42" ~started_at:"t0" ~store_tree:"/tree"
      ~session_id:"boot-a" "proj_1" "/tmp/proj_1"
  in
  Projects.upsert conn p;
  Session.reset_with_boot_id conn ~boot_id:"boot-a";
  (match Projects.get_by_id conn ~id:"proj_1" with
  | None -> Alcotest.fail "proj_1 vanished"
  | Some got ->
      Alcotest.(check (option string))
        "host preserved" (Some "127.0.0.42") got.host;
      Alcotest.(check (option string))
        "session_id preserved" (Some "boot-a") got.session_id);
  Alcotest.(check (option string))
    "meta last_boot_id updated to boot-a"
    (Some "boot-a")
    (Db.meta_get conn ~key:"last_boot_id")

(* ----- transactional rollback semantics ------------------------- *)

(* Session.reset composes an UPDATE on `projects` with an UPSERT on
 * `meta` inside a single `with_transaction`. The whole module relies
 * on caqti's guarantee that a closure returning `Error _` rolls back
 * the preceding statements. This test pins that guarantee: we drive
 * `with_transaction` directly, insert a real row, return `Error`, and
 * assert the row did not land. If caqti ever changes semantics (or we
 * pick a wrong URL), this fails loud instead of silently leaving a
 * half-applied session reset. *)
let test_with_transaction_rollback () =
  eio_run @@ fun ~sw ~stdenv ->
  let conn = fresh_conn ~sw ~stdenv in
  Db.migrate conn;
  let (module C : Caqti_eio.CONNECTION) = conn in
  let insert_req =
    let open Caqti_request.Infix in
    let open Caqti_type.Std in
    (t2 string string ->. unit)
      "INSERT INTO projects (id, path) VALUES (?, ?)"
  in
  let fake_error : [> Caqti_error.t ] =
    (* synthesise a connection error we can use as the Error payload.
     * `Caqti_error.request_failed` would require a real query context;
     * the easiest loud-failure signal is a raw sqlite misuse flagged
     * through caqti by issuing bogus SQL. *)
    let bad_req =
      let open Caqti_request.Infix in
      let open Caqti_type.Std in
      (unit ->. unit) ~oneshot:true "SELECT * FROM no_such_table"
    in
    match C.exec bad_req () with
    | Error e -> e
    | Ok () -> Alcotest.fail "bogus SQL unexpectedly succeeded"
  in
  let result =
    C.with_transaction (fun () ->
        match C.exec insert_req ("rolled_back", "/tmp/x") with
        | Error e -> Error e
        | Ok () -> Error fake_error)
  in
  (match result with
  | Ok () -> Alcotest.fail "transaction should have reported Error"
  | Error _ -> ());
  Alcotest.(check bool)
    "INSERT rolled back" true
    (Projects.get_by_id conn ~id:"rolled_back" = None)

(* ----- foreign-key cascade -------------------------------------- *)

let test_foreign_keys_cascade () =
  eio_run @@ fun ~sw ~stdenv ->
  let conn = fresh_conn ~sw ~stdenv in
  Db.migrate conn;
  Projects.upsert conn (mk_project "proj_1" "/tmp/proj_1");
  Projects.replace_manifest conn ~project_id:"proj_1"
    ~rows:[ ("a.service", "h1"); ("b.service", "h2") ];
  Alcotest.(check int)
    "manifest inserted" 2
    (List.length (Projects.load_manifest conn ~project_id:"proj_1"));
  Projects.delete_by_id conn ~id:"proj_1";
  Alcotest.(check int)
    "manifest rows cascaded (FK = ON)" 0
    (List.length (Projects.load_manifest conn ~project_id:"proj_1"))

(* ---------------------------------------------------------------- *)

let () =
  Alcotest.run "pctl state"
    [
      ( "state",
        [
          Alcotest.test_case "migrate idempotent" `Quick
            test_migrate_idempotent;
          Alcotest.test_case "projects CRUD" `Quick test_projects_crud;
          Alcotest.test_case "manifest replace wipes old" `Quick
            test_manifest_replace;
          Alcotest.test_case "session reset wipes stale" `Quick
            test_session_reset_wipes_stale;
          Alcotest.test_case "session reset no-op same boot" `Quick
            test_session_reset_noop_same_boot;
          Alcotest.test_case "foreign keys cascade delete" `Quick
            test_foreign_keys_cascade;
          Alcotest.test_case "with_transaction rolls back on Error" `Quick
            test_with_transaction_rollback;
        ] );
    ]
