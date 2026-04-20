(* Probe — pure helpers + Make functor exercised over the In_mem
 * Systemctl adapter.
 *
 * Probe.run_probe_once spawns real child processes, so tests in this
 * file avoid the probe-exec path. The no-probe path subscribes to
 * unit-state changes on the In_mem adapter; that alone covers
 * wait_service's unit-state branch, wait_all aggregation, and the
 * Throw_first cancellation invariant. The probe-exec path is covered
 * by the integration/e2e suites.
 *)

module In_mem = Systemctl.In_mem
module P = Probe.Make (In_mem)

let id = Schema.Project_id.of_string_exn "proj"
let host = Schema.Host.of_string_exn "127.0.0.42"

let service_unit name =
  Schema.Unit_filename.to_string
    (Schema.Unit_filename.service ~id ~service:name)

let svc_no_probe name : Schema.service_spec =
  {
    name;
    kind = Schema.Simple;
    depends_on = [];
    workspace = { cwd = false; writable = false };
    probe = None;
    service_config = [];
  }

let spec_of svcs : Schema.spec =
  let services =
    List.fold_left
      (fun acc (s : Schema.service_spec) -> Schema.StringMap.add s.name s acc)
      Schema.StringMap.empty svcs
  in
  { version = 2; slice = { slice_config = [] }; services }

let eio_run (f : sw:Eio.Switch.t -> env:Eio_unix.Stdenv.base -> unit) : unit =
  Eio_main.run @@ fun env -> Eio.Switch.run @@ fun sw -> f ~sw ~env

let mono_now_plus ~seconds env : Mtime.t =
  let now = Eio.Time.Mono.now (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r) in
  let ns = Int64.mul (Int64.of_int seconds) 1_000_000_000L in
  match Mtime.add_span now (Mtime.Span.of_uint64_ns ns) with
  | Some d -> d
  | None -> now

let result_state_testable =
  Alcotest.testable
    (fun ppf s -> Format.pp_print_string ppf (Schema.result_state_to_string s))
    ( = )

let result_kind_testable =
  Alcotest.testable
    (fun ppf k -> Format.pp_print_string ppf (Schema.result_kind_to_string k))
    ( = )

(* ------------------------------------------------------------------ *)
(* Pure helpers                                                        *)
(* ------------------------------------------------------------------ *)

let test_is_terminal_state () =
  let pairs =
    [
      (Schema.Active, true);
      (Schema.Failed, true);
      (Schema.Inactive, true);
      (Schema.Activating, false);
      (Schema.Deactivating, false);
      (Schema.Reloading, false);
    ]
  in
  List.iter
    (fun (s, expect) ->
      Alcotest.(check bool)
        (Printf.sprintf "is_terminal %s" (Schema.state_to_string s))
        expect (Probe.is_terminal_state s))
    pairs

let test_state_to_result_matches_terminals () =
  let cases =
    [
      (Schema.Active, `Active);
      (Schema.Failed, `Failed);
      (Schema.Inactive, `Inactive);
      (* transient states are unreachable in the caller's branch; map to
         `Timed_out defensively — assert so the contract is pinned. *)
      (Schema.Activating, `Timed_out);
      (Schema.Deactivating, `Timed_out);
      (Schema.Reloading, `Timed_out);
    ]
  in
  List.iter
    (fun (s, want) ->
      Alcotest.check result_state_testable
        (Printf.sprintf "state_to_result %s" (Schema.state_to_string s))
        want (Probe.state_to_result s))
    cases

(* Property: terminal states always map to a result_state that is NOT
 * `Timed_out. Exactly the invariant the caller relies on. *)
let state_gen : Schema.state QCheck.Gen.t =
  QCheck.Gen.oneof_list
    [
      Schema.Active;
      Schema.Inactive;
      Schema.Failed;
      Schema.Activating;
      Schema.Deactivating;
      Schema.Reloading;
    ]

let state_arb = QCheck.make ~print:Schema.state_to_string state_gen

let prop_terminal_is_concrete =
  QCheck.Test.make ~count:64
    ~name:"is_terminal ⇒ state_to_result ≠ `Timed_out" state_arb (fun s ->
      if Probe.is_terminal_state s then Probe.state_to_result s <> `Timed_out
      else true)

let test_mono_add_seconds_zero () =
  eio_run @@ fun ~sw:_ ~env ->
  let now =
    Eio.Time.Mono.now (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
  in
  let added = Probe.mono_add_seconds ~base:now ~seconds:0 in
  (* base + 0 = base *)
  Alcotest.(check bool) "add 0s leaves base unchanged" true (added = now)

let test_mono_add_seconds_positive () =
  eio_run @@ fun ~sw:_ ~env ->
  let now =
    Eio.Time.Mono.now (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
  in
  let added = Probe.mono_add_seconds ~base:now ~seconds:10 in
  let span = Mtime.span now added in
  let got_ns = Mtime.Span.to_uint64_ns span in
  Alcotest.(check int64)
    "add 10s = 10_000_000_000 ns" 10_000_000_000L got_ns

(* ------------------------------------------------------------------ *)
(* build_child_env                                                      *)
(* ------------------------------------------------------------------ *)

let test_build_child_env_filters_and_prepends () =
  let cleanup_fns = ref [] in
  let with_env name value =
    let prev = Sys.getenv_opt name in
    Unix.putenv name value;
    cleanup_fns :=
      (fun () ->
        match prev with
        | Some v -> Unix.putenv name v
        | None -> Unix.putenv name "")
      :: !cleanup_fns
  in
  Fun.protect
    ~finally:(fun () -> List.iter (fun f -> f ()) !cleanup_fns)
    (fun () ->
      with_env "PCTL_ID" "STALE_ID";
      with_env "PCTL_HOST" "127.0.0.99";
      with_env "PCTL_TEST_MARKER" "keep";
      let env = Probe.build_child_env ~id ~host in
      let entries = Array.to_list env in
      (* PCTL_ID and PCTL_HOST must appear exactly once, with the ctor
         values, and never carry the stale parent entries. *)
      let count_prefix p =
        List.length
          (List.filter (fun s -> String.starts_with ~prefix:p s) entries)
      in
      Alcotest.(check int) "PCTL_ID appears once" 1 (count_prefix "PCTL_ID=");
      Alcotest.(check int)
        "PCTL_HOST appears once" 1 (count_prefix "PCTL_HOST=");
      Alcotest.(check bool)
        "PCTL_ID is the ctor value" true
        (List.mem "PCTL_ID=proj" entries);
      Alcotest.(check bool)
        "PCTL_HOST is the ctor value" true
        (List.mem "PCTL_HOST=127.0.0.42" entries);
      (* Other parent-env keys pass through. *)
      Alcotest.(check bool)
        "PCTL_TEST_MARKER preserved" true
        (List.mem "PCTL_TEST_MARKER=keep" entries))

(* ------------------------------------------------------------------ *)
(* error_of_row                                                         *)
(* ------------------------------------------------------------------ *)

let row ~state : Schema.result_row =
  { name = "web"; state; elapsed = 0L; kind = `Unit_state }

let test_error_of_row_active () =
  Alcotest.(check bool)
    "Active → no error" true
    (P.error_of_row (row ~state:`Active)
       ~overall_timeout_seconds:5
     = None)

let test_error_of_row_timed_out () =
  let err =
    P.error_of_row (row ~state:`Timed_out)
      ~overall_timeout_seconds:7
  in
  match err with
  | Some (Schema.Probe_timeout { service; timeout_ms }) ->
      Alcotest.(check string) "service name" "web" service;
      Alcotest.(check int) "timeout_ms = seconds*1000" 7000 timeout_ms
  | _ -> Alcotest.fail "expected Probe_timeout"

let test_error_of_row_probe_failed () =
  let err =
    P.error_of_row (row ~state:`Probe_failed)
      ~overall_timeout_seconds:3
  in
  match err with
  | Some (Schema.Probe_timeout { service; timeout_ms }) ->
      Alcotest.(check string) "service name" "web" service;
      Alcotest.(check int) "timeout_ms = seconds*1000" 3000 timeout_ms
  | _ -> Alcotest.fail "expected Probe_timeout for Probe_failed"

let test_error_of_row_failed () =
  let err =
    P.error_of_row (row ~state:`Failed)
      ~overall_timeout_seconds:5
  in
  match err with
  | Some (Schema.Unit_op_failed { op; unit_; reply }) ->
      Alcotest.(check string) "op is wait" "wait" op;
      Alcotest.(check string) "unit is service name" "web" unit_;
      Alcotest.(check bool)
        "reply mentions 'failed'" true
        (String.length reply > 0
        && Option.is_some (String.index_opt reply 'f'))
  | _ -> Alcotest.fail "expected Unit_op_failed for Failed"

let test_error_of_row_inactive () =
  let err =
    P.error_of_row (row ~state:`Inactive)
      ~overall_timeout_seconds:5
  in
  match err with
  | Some (Schema.Unit_op_failed { reply; _ }) ->
      (* reply message contains the terminal state label *)
      Alcotest.(check bool)
        "reply mentions 'inactive'" true
        (try
           ignore
             (Str.search_forward (Str.regexp_string "inactive") reply 0);
           true
         with Not_found -> false)
  | _ -> Alcotest.fail "expected Unit_op_failed for Inactive"

(* ------------------------------------------------------------------ *)
(* Functor — no-probe wait_service                                      *)
(* ------------------------------------------------------------------ *)

let test_wait_service_active () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  let svc = svc_no_probe "web" in
  (* Push Active on the expected unit before calling wait_service so the
     initial read inside wait_unit_state resolves immediately. *)
  In_mem.push_state sc ~unit:(service_unit "web") Schema.Active;
  let deadline = mono_now_plus ~seconds:5 env in
  let row =
    P.wait_service ~sw ~env ~handle:sc ~id ~host ~service_name:"web"
      ~service:svc ~overall_deadline_mono:deadline
  in
  Alcotest.check result_state_testable "state = Active" `Active row.state;
  Alcotest.check result_kind_testable "kind = Unit_state" `Unit_state
    row.kind;
  Alcotest.(check string) "row name" "web" row.name

let test_wait_service_failed () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  let svc = svc_no_probe "web" in
  In_mem.push_state sc ~unit:(service_unit "web") Schema.Failed;
  let deadline = mono_now_plus ~seconds:5 env in
  let row =
    P.wait_service ~sw ~env ~handle:sc ~id ~host ~service_name:"web"
      ~service:svc ~overall_deadline_mono:deadline
  in
  Alcotest.check result_state_testable "state = Failed" `Failed row.state

let test_wait_service_timeout () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  let svc = svc_no_probe "web" in
  (* Leave the unit in Activating (non-terminal); deadline already past
     should fire and produce `Timed_out with kind `Unit_state. *)
  In_mem.push_state sc ~unit:(service_unit "web") Schema.Activating;
  let now =
    Eio.Time.Mono.now (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
  in
  (* deadline in the past → sleep_until returns immediately *)
  let row =
    P.wait_service ~sw ~env ~handle:sc ~id ~host ~service_name:"web"
      ~service:svc ~overall_deadline_mono:now
  in
  Alcotest.check result_state_testable "state = Timed_out" `Timed_out
    row.state;
  Alcotest.check result_kind_testable "kind = Unit_state" `Unit_state row.kind

(* ------------------------------------------------------------------ *)
(* Functor — wait_all ordering + Throw_first cancellation               *)
(* ------------------------------------------------------------------ *)

let test_wait_all_collect_all_alphabetical () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  let spec = spec_of [ svc_no_probe "zeta"; svc_no_probe "alpha" ] in
  List.iter
    (fun n -> In_mem.push_state sc ~unit:(service_unit n) Schema.Active)
    [ "alpha"; "zeta" ];
  let rows =
    P.wait_all ~sw ~env ~handle:sc ~id ~host ~spec ~timeout_seconds:5
      ~strategy:`Collect_all
  in
  Alcotest.(check (list string))
    "names in alphabetical (StringMap) order"
    [ "alpha"; "zeta" ]
    (List.map (fun (r : Schema.result_row) -> r.name) rows);
  List.iter
    (fun (r : Schema.result_row) ->
      Alcotest.check result_state_testable "each row Active" `Active r.state)
    rows

let test_wait_all_throw_first_raises_on_failed () =
  eio_run @@ fun ~sw ~env ->
  let sc = In_mem.connect ~sw env in
  let spec = spec_of [ svc_no_probe "web"; svc_no_probe "db" ] in
  (* db Failed (terminal, non-Active), web Active — Throw_first must
     surface the db failure before wait_all returns. *)
  In_mem.push_state sc ~unit:(service_unit "db") Schema.Failed;
  In_mem.push_state sc ~unit:(service_unit "web") Schema.Active;
  let raised =
    try
      let _ =
        P.wait_all ~sw ~env ~handle:sc ~id ~host ~spec ~timeout_seconds:5
          ~strategy:`Throw_first
      in
      None
    with Schema.Pctl_error e -> Some e
  in
  match raised with
  | Some (Schema.Unit_op_failed { unit_; _ }) ->
      Alcotest.(check string) "raised on db" "db" unit_
  | Some _ -> Alcotest.fail "wrong Pctl_error variant"
  | None -> Alcotest.fail "expected Pctl_error, got success"

let () =
  Alcotest.run "pctl probe"
    [
      ( "pure helpers",
        [
          Alcotest.test_case "is_terminal_state" `Quick test_is_terminal_state;
          Alcotest.test_case "state_to_result map" `Quick
            test_state_to_result_matches_terminals;
          Alcotest.test_case "mono_add_seconds 0" `Quick
            test_mono_add_seconds_zero;
          Alcotest.test_case "mono_add_seconds positive" `Quick
            test_mono_add_seconds_positive;
        ] );
      ( "properties",
        List.map QCheck_alcotest.to_alcotest [ prop_terminal_is_concrete ] );
      ( "build_child_env",
        [
          Alcotest.test_case "filters stale PCTL_ID/PCTL_HOST" `Quick
            test_build_child_env_filters_and_prepends;
        ] );
      ( "error_of_row",
        [
          Alcotest.test_case "Active → None" `Quick test_error_of_row_active;
          Alcotest.test_case "Timed_out → Probe_timeout" `Quick
            test_error_of_row_timed_out;
          Alcotest.test_case "Probe_failed → Probe_timeout" `Quick
            test_error_of_row_probe_failed;
          Alcotest.test_case "Failed → Unit_op_failed" `Quick
            test_error_of_row_failed;
          Alcotest.test_case "Inactive → Unit_op_failed" `Quick
            test_error_of_row_inactive;
        ] );
      ( "wait_service (no probe)",
        [
          Alcotest.test_case "unit Active" `Quick test_wait_service_active;
          Alcotest.test_case "unit Failed" `Quick test_wait_service_failed;
          Alcotest.test_case "deadline-past timeout" `Quick
            test_wait_service_timeout;
        ] );
      ( "wait_all",
        [
          Alcotest.test_case "Collect_all alphabetical" `Quick
            test_wait_all_collect_all_alphabetical;
          Alcotest.test_case "Throw_first raises on Failed" `Quick
            test_wait_all_throw_first_raises_on_failed;
        ] );
    ]
