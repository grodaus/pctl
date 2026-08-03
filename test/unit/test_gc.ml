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

(* Materialise the slice + one service unit [remove_project] would stop
   and delete for [id_s], both in the manifest and under the sandboxed
   user.control, so a test can assert they survive a failed stop. *)
let install_units conn ~id_s =
  let id = Schema.Project_id.of_string_exn id_s in
  let units =
    [
      Schema.Unit_filename.slice ~id;
      Schema.Unit_filename.service ~id ~service:"web";
    ]
  in
  State.Projects.replace_manifest conn ~project_id:id_s
    ~rows:(List.map (fun uf -> (uf, "sha-" ^ id_s)) units);
  let us = Unit_store.Fs.create () in
  List.iter
    (fun unit_ ->
      Unit_store.Fs.write us ~unit_
        { Unit_store.main = "[Unit]\n"; dropin = None })
    units;
  (* Precondition asserted, not assumed: the "files survive" and "files
     deleted" assertions below both pass trivially against an empty
     user.control, so a silently no-op install would turn these tests
     into assertions about nothing. *)
  let present = Unit_store.Fs.list us in
  List.iter
    (fun unit_ ->
      if not (List.exists (Schema.Unit_filename.equal unit_) present) then
        Alcotest.failf "fixture: %s was not installed for %s"
          (Schema.Unit_filename.to_string unit_)
          id_s)
    units;
  units

let unit_names_on_disk () =
  Unit_store.Fs.list (Unit_store.Fs.create ())
  |> List.map Schema.Unit_filename.to_string
  |> List.sort String.compare

let slice_name_of id_s =
  Schema.Unit_filename.to_string
    (Schema.Unit_filename.slice ~id:(Schema.Project_id.of_string_exn id_s))

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
  (* Gc can no longer reach boot_id = "", but class_of_row is pure and
     keeps the guard. *)
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
  (* Same source G.purge classifies against; it never yields "", so there
     is no empty-boot_id case to branch on (pctl-2jn). *)
  let boot = Clock.read_boot_id_exn () in
  upsert_row conn ~id:"live" ~path:xdg ~session_id:boot ();
  upsert_row conn ~id:"orphan" ~path:xdg ~session_id:"stale" ();
  let removed = G.purge ~conn ~handle in
  Alcotest.(check int) "purged 1 orphan, kept 1 live" 1 removed;
  Alcotest.(check (list string))
    "only live row remains" [ "live" ]
    (ids_sorted conn)

(* A slice stop that fails for any reason other than no-such-unit means
   the cgroup cascade never fired: the project's services are still
   running. [remove_project] must abort there rather than delete their
   unit files — that would leave the processes alive in a cgroup with no
   units left to manage them, unreachable by [pctl down] or a later
   [pctl gc]. Because gc is a multi-row loop, the failure is reported
   for that row only and the remaining projects are still purged. *)
let stop_failure_name = Systemctl.Bus_errors.no_reply

let stop_failure_reply = stop_failure_name ^ ": Remote peer disconnected"

(* The pair the Dbus adapter raises for that failure, as In_mem replays
   it: the wire name callers classify on plus the rendered reply. *)
let arm_failing_stop handle ~unit_ =
  Systemctl.In_mem.fail_next_stop handle ~unit:unit_
    ~error_name:(Some stop_failure_name) ~reply:stop_failure_reply

(* The per-row warning is the only report a skipped project gets, so a
   Pctl_error must render as itself, not as "Pctl_error(_)". *)
let test_describe_exn_renders_pctl_error () =
  let e =
    Schema.Pctl_error
      (Schema.Unit_op_failed
         {
           op = "StopUnit";
           unit_ = "pctl-x.slice";
           error_name = Some stop_failure_name;
           reply = stop_failure_reply;
         })
  in
  Alcotest.(check string)
    "renders the systemctl failure"
    ("systemctl StopUnit pctl-x.slice failed: " ^ stop_failure_reply)
    (Gc.describe_exn e);
  (* The property the helper exists for: the stdlib rendering drops the
     payload, so the warning would name no unit and no reply. *)
  Alcotest.(check bool)
    "Printexc alone loses the reply" false
    (Test_helpers.contains_substring (Printexc.to_string e)
       stop_failure_reply)

let test_purge_skips_row_whose_stop_fails () =
  with_sandbox @@ fun ~sw:_ ~env:_ ~conn ~handle ~xdg ->
  upsert_row conn ~id:"a_fails" ~path:xdg ~session_id:"stale" ();
  upsert_row conn ~id:"b_ok" ~path:xdg ~session_id:"stale" ();
  let kept = install_units conn ~id_s:"a_fails" in
  let _ = install_units conn ~id_s:"b_ok" in
  arm_failing_stop handle ~unit_:(slice_name_of "a_fails");
  let removed = G.purge ~conn ~handle in
  Alcotest.(check int) "only the healthy row counted as removed" 1 removed;
  Alcotest.(check (list string))
    "failed row survives for a later retry" [ "a_fails" ] (ids_sorted conn);
  Alcotest.(check (list string))
    "its unit files survive too"
    (List.sort String.compare
       (List.map Schema.Unit_filename.to_string kept))
    (unit_names_on_disk ());
  Alcotest.(check int)
    "and its manifest is intact" 2
    (List.length (State.Projects.load_manifest conn ~project_id:"a_fails"))

(* The one stop failure gc may ignore: the unit was never loaded, so
   there is nothing to cascade and nothing still running. *)
let test_purge_tolerates_no_such_unit_stop () =
  with_sandbox @@ fun ~sw:_ ~env:_ ~conn ~handle ~xdg ->
  upsert_row conn ~id:"a_orphan" ~path:xdg ~session_id:"stale" ();
  let _ = install_units conn ~id_s:"a_orphan" in
  let slice = slice_name_of "a_orphan" in
  Systemctl.In_mem.fail_next_stop handle ~unit:slice
    ~error_name:(Some Systemctl.Bus_errors.no_such_unit)
    ~reply:
      (Systemctl.Bus_errors.no_such_unit ^ ": Unit " ^ slice ^ " not loaded.");
  let removed = G.purge ~conn ~handle in
  Alcotest.(check int) "row still purged" 1 removed;
  Alcotest.(check (list string)) "DB is empty" [] (ids_sorted conn);
  Alcotest.(check (list string)) "unit files deleted" [] (unit_names_on_disk ())

let test_sweep_skips_row_whose_stop_fails () =
  with_sandbox @@ fun ~sw:_ ~env:_ ~conn ~handle ~xdg:_ ->
  upsert_row conn ~id:"a_fails" ~path:"/no/such/path" ~session_id:"stale" ();
  upsert_row conn ~id:"b_ok" ~path:"/no/such/path" ~session_id:"stale" ();
  let kept = install_units conn ~id_s:"a_fails" in
  let _ = install_units conn ~id_s:"b_ok" in
  arm_failing_stop handle ~unit_:(slice_name_of "a_fails");
  G.opportunistic_sweep ~conn ~handle;
  Alcotest.(check (list string))
    "failed row survives, sibling still swept" [ "a_fails" ] (ids_sorted conn);
  Alcotest.(check (list string))
    "its unit files survive"
    (List.sort String.compare
       (List.map Schema.Unit_filename.to_string kept))
    (unit_names_on_disk ())

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
          Alcotest.test_case "stop failure skips only that row" `Quick
            test_sweep_skips_row_whose_stop_fails;
        ] );
      ( "purge",
        [
          Alcotest.test_case "removes Orphan + Unknown" `Quick
            test_purge_removes_orphan_and_unknown;
          Alcotest.test_case "preserves Live" `Quick
            test_purge_preserves_live_rows;
          Alcotest.test_case "stop failure skips only that row" `Quick
            test_purge_skips_row_whose_stop_fails;
          Alcotest.test_case "tolerates no-such-unit stop" `Quick
            test_purge_tolerates_no_such_unit_stop;
        ] );
      ( "describe_exn",
        [
          Alcotest.test_case "renders Pctl_error" `Quick
            test_describe_exn_renders_pctl_error;
        ] );
    ]
