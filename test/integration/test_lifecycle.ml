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

let svc_simple ?(command = [ "/bin/true" ]) name : Schema.service_spec =
  {
    name;
    kind = Schema.Simple;
    command;
    depends_on = [];
    workspace = { cwd = false; writable = false };
    probe = None;
    service_config = [ ("Type", "simple") ];
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

let test_reload_one_service_changed () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  let s1 = spec_of_services [ svc_simple "web"; svc_simple "db" ] in
  let _ = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:s1 () in
  let s2 =
    spec_of_services
      [ svc_simple ~command:[ "/bin/true"; "--changed" ] "web"; svc_simple "db" ]
  in
  let r = L.reload ~conn ~handle ~unit_store:us ~ctx ~spec:(Some s2) () in
  let changed =
    List.filter (fun (r : Schema.plan_row) -> r.action = Schema.Changed) r.diff
  in
  Alcotest.(check int) "exactly one Changed row" 1 (List.length changed);
  let unchanged =
    List.filter
      (fun (r : Schema.plan_row) -> r.action = Schema.Unchanged)
      r.diff
  in
  Alcotest.(check int) "two Unchanged rows (slice + db)" 2
    (List.length unchanged);
  Alcotest.(check bool)
    "web is the Changed one" true
    (List.exists
       (fun (row : Schema.plan_row) ->
         Schema.Unit_filename.equal row.unit_ (service_unit "web"))
       changed)

(* The failure In_mem replays for an injected stop: the wire name callers
   classify on, plus the reply the Dbus adapter would render from it. [op]
   is "StopUnit" — the Manager method name the real adapter raises with, so
   an assertion on it pins a label that exists in production. *)
let arm_failing_stop handle ~unit_ =
  Systemctl.In_mem.fail_next_stop handle ~unit:unit_
    ~error_name:(Some "org.freedesktop.DBus.Error.NoReply")
    ~reply:"org.freedesktop.DBus.Error.NoReply: Remote peer disconnected"

(* The one stop failure the lifecycle tolerates, as systemd words it —
   recorded against systemd 260.1, `dbus-send --session --print-reply …
   Manager.StopUnit` on an unloaded unit. *)
let arm_no_such_unit_stop handle ~unit_ =
  Systemctl.In_mem.fail_next_stop handle ~unit:unit_
    ~error_name:(Some Systemctl.Bus_errors.no_such_unit)
    ~reply:
      (Systemctl.Bus_errors.no_such_unit ^ ": Unit " ^ unit_
      ^ " not loaded.")

(* A slice stop that fails for any reason other than no-such-unit means
   the cgroup cascade never fired: the services are still running. Down
   must abort there rather than unload the slice and delete the unit
   files, which would leave those processes alive in a cgroup with no
   units left to manage them — invisible to [pctl status], unreachable
   by [pctl down]. *)
let test_down_propagates_stop_failure () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  let s = spec_of_services [ svc_simple "web" ] in
  let _ = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:s () in
  let slice_s = Schema.Unit_filename.to_string slice_unit in
  arm_failing_stop handle ~unit_:slice_s;
  let raised =
    try
      let _ = L.down ~conn ~handle ~unit_store:us ~ctx () in
      false
    with
    | Schema.Pctl_error (Schema.Unit_op_failed { op = "StopUnit"; _ }) -> true
  in
  Alcotest.(check bool) "down raised Unit_op_failed" true raised;
  (* The units the still-running services depend on must survive, both on
     disk and in the persisted manifest, so a retried [pctl down] can
     still find and stop them. *)
  Alcotest.(check int)
    "units left in store" 2
    (List.length (Unit_store.In_mem.list us));
  Alcotest.(check int)
    "manifest left intact" 2
    (List.length
       (State.Projects.load_manifest conn
          ~project_id:(Schema.Project_id.to_string id)));
  let row_after =
    State.Projects.get_by_id conn ~id:(Schema.Project_id.to_string id)
  in
  match row_after with
  | None -> Alcotest.fail "project row vanished after failed down"
  | Some r ->
      Alcotest.(check (option string))
        "host still allocated"
        (Some (Schema.Host.to_string host))
        r.host

(* The one stop failure down may ignore: the slice was never loaded, so
   there is nothing to cascade and nothing still running. *)
let test_down_tolerates_no_such_unit () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  let s = spec_of_services [ svc_simple "web" ] in
  let _ = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:s () in
  let slice_s = Schema.Unit_filename.to_string slice_unit in
  arm_no_such_unit_stop handle ~unit_:slice_s;
  let r = L.down ~conn ~handle ~unit_store:us ~ctx () in
  Alcotest.(check int) "down cleared manifest" 0 r.units_on_disk;
  Alcotest.(check int)
    "store empty" 0
    (List.length (Unit_store.In_mem.list us))

(* Reload a two-service spec down to one, so the dropped service's row is
   [Removed]. Its unit file is deleted BEFORE the stop is issued, so the
   two stop outcomes are not symmetric:

   - no-such-unit means systemd already GCed the fileless unit — nothing
     to stop, nothing running, so the reload finishes;
   - anything else means the process is still alive and its unit file is
     already gone, which is the one state [pctl status] and [pctl down]
     cannot see. It must be reported, not tolerated. *)
let reload_dropping_api handle conn us =
  let both = spec_of_services [ svc_simple "web"; svc_simple "api" ] in
  let _ = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:both () in
  let api_s = Schema.Unit_filename.to_string (service_unit "api") in
  (api_s, spec_of_services [ svc_simple "web" ])

let test_reload_propagates_removed_stop_failure () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  let api_s, only_web = reload_dropping_api handle conn us in
  arm_failing_stop handle ~unit_:api_s;
  let raised =
    try
      let _ = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:only_web () in
      false
    with
    | Schema.Pctl_error (Schema.Unit_op_failed { op = "StopUnit"; unit_; _ }) ->
        Alcotest.(check string) "names the removed unit" api_s unit_;
        true
  in
  Alcotest.(check bool) "reload raised Unit_op_failed" true raised;
  (* The manifest is not replaced, so the next reload still sees the
     dropped service as [Removed] and retries the stop. *)
  Alcotest.(check int)
    "manifest still lists both services" 3
    (List.length
       (State.Projects.load_manifest conn
          ~project_id:(Schema.Project_id.to_string id)))

let test_reload_tolerates_removed_no_such_unit_stop () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  let api_s, only_web = reload_dropping_api handle conn us in
  arm_no_such_unit_stop handle ~unit_:api_s;
  let r = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:only_web () in
  Alcotest.(check int) "slice + web remain" 2 r.units_on_disk;
  Alcotest.(check bool)
    "api unit file removed" false
    (List.exists
       (Schema.Unit_filename.equal (service_unit "api"))
       (Unit_store.In_mem.list us))

let test_up_fail_next_write () =
  with_sandbox @@ fun ~sw:_ ~conn ~handle ~us ->
  Unit_store.In_mem.fail_next_write us ~reason:"injected disk-full";
  let s = spec_of_services [ svc_simple "web" ] in
  let raised =
    try
      let _ = L.up ~conn ~handle ~unit_store:us ~ctx ~spec:s () in
      false
    with Schema.Pctl_error (Schema.Install_failed _) -> true
  in
  Alcotest.(check bool) "up raised Install_failed" true raised;
  let stored =
    State.Projects.load_manifest conn
      ~project_id:(Schema.Project_id.to_string id)
  in
  Alcotest.(check int) "no partial manifest persisted" 0 (List.length stored);
  Alcotest.(check int)
    "unit_store still empty" 0
    (List.length (Unit_store.In_mem.list us))

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
          Alcotest.test_case "reload one service Changed" `Quick
            test_reload_one_service_changed;
          Alcotest.test_case "reload drop-in only change" `Quick
            test_reload_dropin_only_change;
          Alcotest.test_case "down after up" `Quick test_down_after_up;
          Alcotest.test_case "down propagates stop failure" `Quick
            test_down_propagates_stop_failure;
          Alcotest.test_case "down tolerates no-such-unit stop" `Quick
            test_down_tolerates_no_such_unit;
          Alcotest.test_case "reload propagates a Removed row's stop failure"
            `Quick test_reload_propagates_removed_stop_failure;
          Alcotest.test_case "reload tolerates a Removed row's no-such-unit stop"
            `Quick test_reload_tolerates_removed_no_such_unit_stop;
          Alcotest.test_case "up fail_next_write → Install_failed" `Quick
            test_up_fail_next_write;
        ] );
    ]
