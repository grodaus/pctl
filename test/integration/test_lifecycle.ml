(* Lifecycle — in-process integration test against In_mem adapters.
 *
 * Exercises the full up → idempotent up → down path without touching
 * the filesystem, real systemd, or pipeline.ml. Phase 6 expands this
 * suite with drop-in-only changes, stop-failure injection, and
 * fail_next_write recovery scenarios. *)

module L = Lifecycle.Make (Systemctl.In_mem) (Unit_store.In_mem)

let memory_uri = Uri.of_string "sqlite3::memory:"

let id = Schema.Project_id.of_string_exn "proj_lifecycle"
let host = Schema.Host.of_string_exn "127.0.0.42"
let project_path = Schema.Project_path.of_raw "/tmp/pctl-lifecycle-test"

let ctx : Lifecycle.ctx = { id; host; project_path }

let svc_simple name : Schema.service_spec =
  {
    name;
    kind = Schema.Simple;
    depends_on = [];
    workspace = { cwd = false; writable = false };
    probe = None;
    service_config = [ ("ExecStart", "/bin/true"); ("Type", "simple") ];
  }

let spec_of_services (svcs : Schema.service_spec list) : Schema.spec =
  let services =
    List.fold_left
      (fun acc (s : Schema.service_spec) -> Schema.StringMap.add s.name s acc)
      Schema.StringMap.empty svcs
  in
  { version = 2; slice = { slice_config = [] }; services }

let slice_unit : Schema.Unit_filename.t = Schema.Unit_filename.slice ~id

let service_unit n : Schema.Unit_filename.t =
  Schema.Unit_filename.service ~id ~service:n

let action_testable =
  Alcotest.testable
    (fun ppf a -> Format.fprintf ppf "%s" (Schema.action_to_string a))
    ( = )

let with_sandbox
    (f :
      sw:Eio.Switch.t ->
      conn:State.Db.t ->
      handle:Systemctl.In_mem.t ->
      us:Unit_store.In_mem.t ->
      unit) =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let stdenv : Caqti_eio.stdenv =
    object
      method net = (env#net :> [ `Generic ] Eio.Net.ty Eio.Std.r)
      method clock = (env#clock :> float Eio.Time.clock_ty Eio.Std.r)
      method mono_clock = (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
    end
  in
  let conn = State.Db.connect_uri ~sw ~stdenv memory_uri in
  State.Db.migrate conn;
  State.Projects.upsert conn
    {
      id = Schema.Project_id.to_string id;
      path = Schema.Project_path.to_string project_path;
      host = Some (Schema.Host.to_string host);
      started_at = Some "2026-01-01T00:00:00+00:00";
      spec_file = None;
      session_id = Some "test-boot";
      spec_json = None;
    };
  let handle = Systemctl.In_mem.connect ~sw env in
  let us = Unit_store.In_mem.create () in
  f ~sw ~conn ~handle ~us

let test_up_fresh () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  let s = spec_of_services [ svc_simple "web"; svc_simple "db" ] in
  let r = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:s () in
  Alcotest.(check int) "3 units on disk" 3 r.units_on_disk;
  Alcotest.(check int) "diff = 3 rows" 3 (List.length r.diff);
  List.iter
    (fun (row : Schema.plan_row) ->
      Alcotest.check action_testable "all rows Added" Schema.Added row.action)
    r.diff;
  Alcotest.(check int)
    "3 units in store" 3
    (List.length (Unit_store.In_mem.list us));
  let active =
    Systemctl.In_mem.inspect handle
    |> List.filter (fun (_, s) -> s = Schema.Active)
    |> List.map fst |> List.sort String.compare
  in
  Alcotest.(check (list string))
    "slice + services active"
    [
      Schema.Unit_filename.to_string (service_unit "db");
      Schema.Unit_filename.to_string (service_unit "web");
      Schema.Unit_filename.to_string slice_unit;
    ]
    active

let test_up_idempotent () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  let s = spec_of_services [ svc_simple "web" ] in
  let _ = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:s () in
  let r2 = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:s () in
  List.iter
    (fun (row : Schema.plan_row) ->
      Alcotest.check action_testable "row Unchanged" Schema.Unchanged
        row.action)
    r2.diff

(* Phase 4 guarantee: if only the drop-in bytes change (here: the host
   allocated to the project rotates), the manifest diff must report
   the affected services as [Changed]. Before drop-in hashing the
   main-unit bytes were identical across host changes, so a host
   rotation silently skipped the reload. *)
let test_reload_dropin_only_change () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  let s = spec_of_services [ svc_simple "web"; svc_simple "db" ] in
  let _ = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:s () in
  let host_new = Schema.Host.of_string_exn "127.0.0.99" in
  let ctx_new = { ctx with host = host_new } in
  let r =
    L.reload ~conn ~handle ~unit_store:us ~ctx:ctx_new ~spec:(Some s) ()
  in
  let by_action =
    List.fold_left
      (fun (changed, other) (row : Schema.plan_row) ->
        match row.action with
        | Schema.Changed -> (row :: changed, other)
        | _ -> (changed, row :: other))
      ([], []) r.diff
  in
  let changed, other = by_action in
  (* The slice's drop-in is always None (Environment= is Service-only),
     so the slice's hash is host-independent and should stay Unchanged. *)
  Alcotest.(check int) "2 services Changed on host rotation" 2
    (List.length changed);
  Alcotest.(check bool)
    "slice Unchanged" true
    (List.exists
       (fun (r : Schema.plan_row) ->
         Schema.Unit_filename.equal r.unit_ slice_unit
         && r.action = Schema.Unchanged)
       other)

let test_down_after_up () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  let s = spec_of_services [ svc_simple "web" ] in
  let _ = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:s () in
  let r = L.down ~conn ~handle ~unit_store:us ~ctx () in
  Alcotest.(check int) "nothing on disk after down" 0 r.units_on_disk;
  Alcotest.(check int)
    "store empty after down" 0
    (List.length (Unit_store.In_mem.list us));
  let row_after =
    State.Projects.get_by_id conn ~id:(Schema.Project_id.to_string id)
  in
  (match row_after with
  | None -> Alcotest.fail "project row vanished after down"
  | Some r -> Alcotest.(check (option string)) "host cleared" None r.host);
  let slice_s = Schema.Unit_filename.to_string slice_unit in
  Alcotest.(check bool)
    "slice not active" false
    (Systemctl.In_mem.unit_state handle ~unit:slice_s = Schema.Active)

let () =
  Alcotest.run "lifecycle"
    [
      ( "primitives",
        [
          Alcotest.test_case "up fresh" `Quick test_up_fresh;
          Alcotest.test_case "up idempotent" `Quick test_up_idempotent;
          Alcotest.test_case "reload drop-in only change" `Quick
            test_reload_dropin_only_change;
          Alcotest.test_case "down after up" `Quick test_down_after_up;
        ] );
    ]
