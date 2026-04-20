(* Gc — opportunistic sweep + explicit purge, over an in-memory SQLite
 * DB and the In_mem Systemctl adapter. Unit_store.Fs is used directly
 * by [remove_project] (hard-coded), so tests sandbox XDG_RUNTIME_DIR
 * under a per-test tmpdir to keep filesystem side effects contained. *)

module In_mem = Systemctl.In_mem
module G = Gc.Make (In_mem)

let memory_uri = Uri.of_string "sqlite3::memory:"

let eio_run (f : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> unit) : unit =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw -> f ~sw ~env

let with_sandbox
    (f :
      sw:Eio.Switch.t ->
      env:Eio_unix.Stdenv.base ->
      conn:State.Db.t ->
      handle:In_mem.t ->
      xdg:string ->
      unit) =
  eio_run @@ fun ~sw ~env ->
  Test_helpers.with_tmpdir @@ fun xdg ->
  Test_helpers.with_env ~name:"XDG_RUNTIME_DIR" ~value:(Some xdg) @@ fun () ->
  let stdenv : Caqti_eio.stdenv =
    object
      method net = (env#net :> [ `Generic ] Eio.Net.ty Eio.Std.r)
      method clock = (env#clock :> float Eio.Time.clock_ty Eio.Std.r)
      method mono_clock = (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
    end
  in
  let conn = State.Db.connect_uri ~sw ~stdenv memory_uri in
  State.Db.migrate conn;
  let handle = In_mem.connect ~sw env in
  f ~sw ~env ~conn ~handle ~xdg

let upsert_row conn ~id ~path ?host ?session_id () =
  State.Projects.upsert conn
    {
      id;
      path;
      host;
      started_at = None;
      spec_file = None;
      session_id;
      spec_json = None;
    }

let class_testable =
  Alcotest.testable
    (fun ppf c -> Format.pp_print_string ppf (Schema.class_to_string c))
    ( = )

let ids_sorted conn =
  State.Projects.all conn
  |> List.map (fun (r : State.Projects.t) -> r.id)
  |> List.sort String.compare

(* ------------------------------------------------------------------ *)
(* no_gc_env                                                           *)
(* ------------------------------------------------------------------ *)

let test_no_gc_env_set_1 () =
  Test_helpers.with_env ~name:"PCTL_NO_GC" ~value:(Some "1") @@ fun () ->
  Alcotest.(check bool) "PCTL_NO_GC=1 disables" true (Gc.no_gc_env ())

let test_no_gc_env_unset () =
  Test_helpers.with_env ~name:"PCTL_NO_GC" ~value:None @@ fun () ->
  Alcotest.(check bool) "unset enables" false (Gc.no_gc_env ())

let test_no_gc_env_other_value () =
  Test_helpers.with_env ~name:"PCTL_NO_GC" ~value:(Some "0") @@ fun () ->
  Alcotest.(check bool) "value '0' enables" false (Gc.no_gc_env ())

(* ------------------------------------------------------------------ *)
(* class_of_row                                                        *)
(* ------------------------------------------------------------------ *)

let test_class_unknown_missing_path () =
  let row : State.Projects.t =
    {
      id = "x";
      path = "/tmp/definitely-not-a-real-path-" ^ string_of_int (Random.bits ());
      host = None;
      started_at = None;
      spec_file = None;
      session_id = Some "any-boot";
      spec_json = None;
    }
  in
  Alcotest.check class_testable "missing path → Unknown" Schema.Unknown
    (Gc.class_of_row ~boot_id:"any-boot" row)

let test_class_live_matching_boot () =
  Test_helpers.with_tmpdir @@ fun path ->
  let row : State.Projects.t =
    {
      id = "x";
      path;
      host = None;
      started_at = None;
      spec_file = None;
      session_id = Some "boot-A";
      spec_json = None;
    }
  in
  Alcotest.check class_testable "session_id = boot_id → Live" Schema.Live
    (Gc.class_of_row ~boot_id:"boot-A" row)

let test_class_orphan_mismatch () =
  Test_helpers.with_tmpdir @@ fun path ->
  let row : State.Projects.t =
    {
      id = "x";
      path;
      host = None;
      started_at = None;
      spec_file = None;
      session_id = Some "boot-STALE";
      spec_json = None;
    }
  in
  Alcotest.check class_testable "mismatch → Orphan" Schema.Orphan
    (Gc.class_of_row ~boot_id:"boot-CURRENT" row)

let test_class_orphan_null_session () =
  Test_helpers.with_tmpdir @@ fun path ->
  let row : State.Projects.t =
    {
      id = "x";
      path;
      host = None;
      started_at = None;
      spec_file = None;
      session_id = None;
      spec_json = None;
    }
  in
  Alcotest.check class_testable "NULL session_id → Orphan" Schema.Orphan
    (Gc.class_of_row ~boot_id:"boot-A" row)

let test_class_empty_boot_id_never_live () =
  (* Edge: if current_boot_id () returns "" (e.g. /proc unavailable),
     a row with session_id = Some "" must still be Orphan, not Live. *)
  Test_helpers.with_tmpdir @@ fun path ->
  let row : State.Projects.t =
    {
      id = "x";
      path;
      host = None;
      started_at = None;
      spec_file = None;
      session_id = Some "";
      spec_json = None;
    }
  in
  Alcotest.check class_testable "empty boot_id and empty session ≠ Live"
    Schema.Orphan
    (Gc.class_of_row ~boot_id:"" row)

(* ------------------------------------------------------------------ *)
(* report                                                              *)
(* ------------------------------------------------------------------ *)

let test_report_orders_by_id_and_classifies () =
  with_sandbox @@ fun ~sw:_ ~env:_ ~conn ~handle:_ ~xdg ->
  (* One Orphan (path exists, session mismatch), one Unknown (path missing). *)
  upsert_row conn ~id:"b_missing" ~path:"/no/such/path" ~session_id:"stale"
    ();
  upsert_row conn ~id:"a_orphan" ~path:xdg ~session_id:"stale" ();
  let rep = Gc.report ~conn in
  let got =
    List.map
      (fun ((r : State.Projects.t), c) -> (r.id, c))
      rep
  in
  (* all() orders by id lexicographically. *)
  Alcotest.(check (list (pair string class_testable)))
    "report rows in id order" [
      ("a_orphan", Schema.Orphan);
      ("b_missing", Schema.Unknown);
    ] got

(* ------------------------------------------------------------------ *)
(* opportunistic_sweep                                                 *)
(* ------------------------------------------------------------------ *)

let test_sweep_removes_unknown_only () =
  with_sandbox @@ fun ~sw:_ ~env:_ ~conn ~handle ~xdg ->
  upsert_row conn ~id:"keep_orphan" ~path:xdg ~session_id:"stale" ();
  upsert_row conn ~id:"drop_unknown" ~path:"/no/such/path"
    ~session_id:"stale" ();
  G.opportunistic_sweep ~conn ~handle;
  Alcotest.(check (list string))
    "Unknown dropped, Orphan kept" [ "keep_orphan" ] (ids_sorted conn)

let test_sweep_respects_pctl_no_gc () =
  with_sandbox @@ fun ~sw:_ ~env:_ ~conn ~handle ~xdg ->
  upsert_row conn ~id:"drop_unknown" ~path:"/no/such/path"
    ~session_id:"stale" ();
  Test_helpers.with_env ~name:"PCTL_NO_GC" ~value:(Some "1") (fun () ->
      G.opportunistic_sweep ~conn ~handle);
  (* With sweep disabled the Unknown row must still be present. *)
  Alcotest.(check (list string))
    "PCTL_NO_GC leaves rows alone"
    [ "drop_unknown" ]
    (ids_sorted conn);
  let _ = xdg in
  ()

let test_sweep_noop_when_empty () =
  with_sandbox @@ fun ~sw:_ ~env:_ ~conn ~handle ~xdg:_ ->
  G.opportunistic_sweep ~conn ~handle;
  Alcotest.(check (list string)) "no rows survives" [] (ids_sorted conn)

(* ------------------------------------------------------------------ *)
(* purge                                                                *)
(* ------------------------------------------------------------------ *)

let test_purge_removes_orphan_and_unknown () =
  with_sandbox @@ fun ~sw:_ ~env:_ ~conn ~handle ~xdg ->
  upsert_row conn ~id:"a_orphan" ~path:xdg ~session_id:"stale" ();
  upsert_row conn ~id:"b_unknown" ~path:"/no/such/path" ~session_id:"stale"
    ();
  let removed = G.purge ~conn ~handle in
  Alcotest.(check int) "purged 2 rows" 2 removed;
  Alcotest.(check (list string)) "DB is empty" [] (ids_sorted conn)

let test_purge_preserves_live_rows () =
  with_sandbox @@ fun ~sw:_ ~env:_ ~conn ~handle ~xdg ->
  (* To fabricate a Live row we need session_id = current_boot_id (). If
     boot_id is empty (e.g. no /proc), this test degenerates to "no
     row is Live, so purge removes everything" — which is still a
     correct contract, so we assert based on the actual boot_id at
     runtime. *)
  let boot = Gc.current_boot_id () in
  upsert_row conn ~id:"live" ~path:xdg ~session_id:boot ();
  upsert_row conn ~id:"orphan" ~path:xdg ~session_id:"stale" ();
  let removed = G.purge ~conn ~handle in
  let remaining = ids_sorted conn in
  if boot <> "" then begin
    Alcotest.(check int) "purged 1 orphan, kept 1 live" 1 removed;
    Alcotest.(check (list string))
      "only live row remains" [ "live" ] remaining
  end
  else begin
    Alcotest.(check int) "empty boot_id → both removed" 2 removed;
    Alcotest.(check (list string)) "nothing remains" [] remaining
  end

let () =
  Alcotest.run "pctl gc"
    [
      ( "no_gc_env",
        [
          Alcotest.test_case "PCTL_NO_GC=1 → true" `Quick test_no_gc_env_set_1;
          Alcotest.test_case "unset → false" `Quick test_no_gc_env_unset;
          Alcotest.test_case "other value → false" `Quick
            test_no_gc_env_other_value;
        ] );
      ( "class_of_row",
        [
          Alcotest.test_case "missing path → Unknown" `Quick
            test_class_unknown_missing_path;
          Alcotest.test_case "matching boot_id → Live" `Quick
            test_class_live_matching_boot;
          Alcotest.test_case "session_id mismatch → Orphan" `Quick
            test_class_orphan_mismatch;
          Alcotest.test_case "NULL session_id → Orphan" `Quick
            test_class_orphan_null_session;
          Alcotest.test_case "empty boot_id never Live" `Quick
            test_class_empty_boot_id_never_live;
        ] );
      ( "report",
        [
          Alcotest.test_case "order + classify" `Quick
            test_report_orders_by_id_and_classifies;
        ] );
      ( "opportunistic_sweep",
        [
          Alcotest.test_case "Unknown removed, Orphan kept" `Quick
            test_sweep_removes_unknown_only;
          Alcotest.test_case "PCTL_NO_GC disables" `Quick
            test_sweep_respects_pctl_no_gc;
          Alcotest.test_case "empty DB" `Quick test_sweep_noop_when_empty;
        ] );
      ( "purge",
        [
          Alcotest.test_case "removes Orphan + Unknown" `Quick
            test_purge_removes_orphan_and_unknown;
          Alcotest.test_case "preserves Live" `Quick
            test_purge_preserves_live_rows;
        ] );
    ]
