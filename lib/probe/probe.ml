(* Probe — per-service readiness wait + parallel aggregator.
 *
 * Plan binding: docs/src/plans/20260419-ocaml-rewrite.md
 * §"Readiness wait algorithm" and §"Readiness (up --wait, results)".
 * Behavioural oracle: pctl/lib/probe.nu {wait-probe, wait-ready,
 * wait-all, unit-state, wait-active-unit}.
 *
 * Two public entry points:
 *
 * - [wait_service]: single-fiber wait for one service. Returns a
 *   [Schema.result_row] describing terminal outcome. Never raises for
 *   "probe failed" / "unit failed" — the error is encoded in
 *   [result_row.state].
 *
 * - [wait_all]: parallelises wait_service across every service in the
 *   spec. Shares one [overall_deadline] across fibers so --timeout
 *   bounds the whole wait, not each probe. Two strategies:
 *     * [`Throw_first] — first non-Active result raises inside an
 *       inner Switch, which re-raises from [Switch.run] and cancels
 *       all sibling fibers.
 *     * [`Collect_all] — every fiber runs to completion; we aggregate
 *       the list in StringMap order (alphabetical, mirroring the
 *       Nushell `wait-all` which sorts service names before iterating).
 *
 * Timing: [elapsed] is nanoseconds measured via Eio's monotonic clock,
 * spanning the duration of the single [wait_service] invocation.
 *)

(* ------------------------------------------------------------------ *)
(* Strategy — how [wait_all] handles non-Active outcomes.               *)
(* ------------------------------------------------------------------ *)

type strategy = [ `Throw_first | `Collect_all ]

(* ------------------------------------------------------------------ *)
(* Internal helpers.                                                    *)
(* ------------------------------------------------------------------ *)

(* Terminal states for the no-probe path. The Nushell oracle treats
 * Active as success; Failed/Inactive as terminal failure; the three
 * transient states (Activating/Deactivating/Reloading) as "keep
 * waiting". See pctl/lib/probe.nu `wait-active-unit`. *)
let is_terminal_state : Schema.state -> bool = function
  | Schema.Active | Schema.Failed | Schema.Inactive -> true
  | Schema.Activating | Schema.Deactivating | Schema.Reloading -> false

(* Terminal systemd state → result state. Only called after
 * [is_terminal_state] returned true, so the transient cases here are
 * unreachable — they map to [`Timed_out] for safety. *)
let state_to_result : Schema.state -> Schema.result_state = function
  | Schema.Active -> `Active
  | Schema.Failed -> `Failed
  | Schema.Inactive -> `Inactive
  | Schema.Activating | Schema.Deactivating | Schema.Reloading -> `Timed_out

let mono_now env =
  Eio.Time.Mono.now (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)

(* Elapsed ns between [start_mono] and now. *)
let elapsed_ns ~start_mono env : int64 =
  let now = mono_now env in
  Mtime.Span.to_uint64_ns (Mtime.span start_mono now)

(* Add [n] seconds to [t], saturating to [t] on overflow. *)
let mono_add_seconds ~(base : Mtime.t) ~(seconds : int) : Mtime.t =
  let ns = Int64.mul (Int64.of_int seconds) 1_000_000_000L in
  match Mtime.add_span base (Mtime.Span.of_uint64_ns ns) with
  | Some d -> d
  | None -> base

(* ------------------------------------------------------------------ *)
(* Probe executor — spawn the probe with PCTL_HOST/PCTL_ID, await exit. *)
(* Returns true iff exit-0.                                             *)
(* ------------------------------------------------------------------ *)

(* Build [string array] env that inherits the current process env plus
 * PCTL_ID / PCTL_HOST. Matches Nushell `with-env {PCTL_ID, PCTL_HOST}`
 * which merges with the parent env. *)
let build_child_env ~(id : Schema.project_id) ~(host : Schema.host) :
    string array =
  let parent =
    Unix.environment () |> Array.to_list
    |> List.filter (fun s ->
           not
             (String.starts_with ~prefix:"PCTL_ID=" s
             || String.starts_with ~prefix:"PCTL_HOST=" s))
  in
  Array.of_list
    (Printf.sprintf "PCTL_ID=%s" (Schema.Project_id.to_string id)
     :: Printf.sprintf "PCTL_HOST=%s" (Schema.Host.to_string host)
     :: parent)

(* Run the probe command ONCE; return true iff exit-0. Any spawn error
 * (executable not found, ...) is treated as false — matches the
 * Nushell `probe-once` behaviour, which keeps the wait alive long
 * enough for a slow-to-appear readiness flag file to materialise.
 *
 * The child's stdout/stderr go to buffer sinks that we discard on exit.
 * We do NOT inherit parent stdout: [pctl results --json] must emit a
 * clean JSON array and a chatty probe would corrupt it. *)
let run_probe_once ~env ~(child_env : string array) ~(exec : string list) :
    bool =
  match exec with
  | [] ->
      (* An empty exec is spec-level nonsense; the Spec loader should
       * have caught this. Defensive: treat as probe_failed. *)
      false
  | _ ->
      Eio.Switch.run @@ fun sw ->
      let proc_mgr = Eio.Stdenv.process_mgr env in
      let sink_buf = Buffer.create 64 in
      let sink = Eio.Flow.buffer_sink sink_buf in
      let proc =
        Eio.Process.spawn ~sw proc_mgr ~stdout:sink ~stderr:sink
          ~env:child_env exec
      in
      match Eio.Process.await proc with `Exited 0 -> true | _ -> false

(* ------------------------------------------------------------------ *)
(* Functor over Systemctl.S — wait_service / wait_all.                  *)
(* ------------------------------------------------------------------ *)

module Make (M : Systemctl.S) = struct
  type handle = M.t

  (* ---- Unit-state wait (no probe declared) ------------------------- *)

  (* Subscribe first, then read [unit_state] ONCE — avoids the race
   * where the unit reaches Active before the subscription is armed.
   * Blocks the caller fiber on a promise resolved by the subscription
   * callback (or by the initial read if it's already terminal).
   * Cancelled externally by the [Fiber.first] wrapper when the
   * deadline fires — that cancellation cancels this fiber before it
   * returns. *)
  let wait_unit_state (handle : M.t) ~(service_unit : string) : Schema.state =
    let p, u = Eio.Promise.create () in
    let resolved = ref false in
    let cb (state : Schema.state) =
      if (not !resolved) && is_terminal_state state then begin
        resolved := true;
        Eio.Promise.resolve u state
      end
    in
    M.subscribe_unit_changes handle ~unit:service_unit cb;
    let initial = M.unit_state handle ~unit:service_unit in
    if is_terminal_state initial && not !resolved then begin
      resolved := true;
      Eio.Promise.resolve u initial
    end;
    Eio.Promise.await p

  (* ---- Single-service entry point ---------------------------------- *)

  (* Per-service deadline = min(overall_deadline, now + probe_timeout_s).
   * The [elapsed] field on the returned row covers the whole fiber's
   * wall clock — from [start_mono] until return. *)
  let wait_service ~sw:_ ~env ~(handle : M.t) ~(id : Schema.project_id)
      ~(host : Schema.host) ~service_name ~(service : Schema.service_spec)
      ~(overall_deadline_mono : Mtime.t) : Schema.result_row =
    let start_mono = mono_now env in
    let service_unit =
      Schema.service_filename ~id ~service_name:service.Schema.name
    in
    let service_deadline =
      match service.Schema.probe with
      | None -> overall_deadline_mono
      | Some p ->
          let per_probe =
            mono_add_seconds ~base:start_mono ~seconds:p.Schema.timeout_seconds
          in
          if Mtime.is_earlier per_probe ~than:overall_deadline_mono then
            per_probe
          else overall_deadline_mono
    in
    let mono_clock = (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r) in
    let make_row state kind =
      {
        Schema.name = service_name;
        state;
        elapsed = elapsed_ns ~start_mono env;
        kind;
      }
    in
    let deadline_fires () =
      Eio.Time.Mono.sleep_until mono_clock service_deadline;
      `Deadline
    in
    match service.Schema.probe with
    | Some probe ->
        let child_env = build_child_env ~id ~host in
        let period_s = float_of_int probe.Schema.period_seconds in
        let rec probe_loop () =
          (* First check is immediate — matches Nushell wait-probe. *)
          if run_probe_once ~env ~child_env ~exec:probe.Schema.exec then
            `Active
          else begin
            let now = mono_now env in
            if not (Mtime.is_earlier now ~than:service_deadline) then
              `Timed_out
            else begin
              Eio.Time.sleep
                (env#clock :> float Eio.Time.clock_ty Eio.Std.r)
                period_s;
              probe_loop ()
            end
          end
        in
        let outcome =
          Eio.Fiber.first probe_loop (fun () ->
              ignore (deadline_fires ());
              `Timed_out)
        in
        let state =
          match outcome with
          | `Active -> `Active
          | `Timed_out ->
              (* If the per-service deadline (probe timeout) fires
               * before the overall, mark as probe-failed; otherwise
               * mark timed-out. Mirrors Nushell:
               *   if $effective < $remaining { "probe-failed" } else { "timed-out" } *)
              if
                Mtime.is_earlier service_deadline
                  ~than:overall_deadline_mono
              then `Probe_failed
              else `Timed_out
        in
        make_row state `Probe
    | None ->
        let outcome =
          Eio.Fiber.first
            (fun () -> `State (wait_unit_state handle ~service_unit))
            deadline_fires
        in
        (match outcome with
         | `State s -> make_row (state_to_result s) `Unit_state
         | `Deadline -> make_row `Timed_out `Unit_state)

  (* ---- Multi-service entry point ---------------------------------- *)

  (* Build a Pctl_error appropriate for each non-Active outcome, used
   * by `Throw_first`. The error message names the service and the
   * terminal state — the Nushell oracle asserts both in
   * wait_failed_oneshot_test and wait_overall_timeout_test. *)
  let error_of_row (r : Schema.result_row) ~overall_timeout_seconds :
      Schema.error option =
    match r.state with
    | `Active -> None
    | `Probe_failed | `Timed_out ->
        Some
          (Schema.Probe_timeout
             { service = r.name; timeout_ms = overall_timeout_seconds * 1000 })
    | (`Failed | `Inactive) as s ->
        let label =
          match s with `Failed -> "failed" | `Inactive -> "inactive"
        in
        Some
          (Schema.Unit_op_failed
             {
               op = "wait";
               unit_ = r.name;
               reply =
                 Printf.sprintf
                   "service %s terminated in state '%s' (expected 'active')"
                   r.name label;
             })

  let wait_all ~sw ~env ~(handle : M.t) ~(id : Schema.project_id)
      ~(host : Schema.host) ~(spec : Schema.spec) ~timeout_seconds
      ~(strategy : strategy) : Schema.result_row list =
    let start_mono = mono_now env in
    let overall_deadline_mono =
      mono_add_seconds ~base:start_mono ~seconds:timeout_seconds
    in
    (* Iterate in StringMap (alphabetical) order — matches Nushell
     * oracle `sort` in pctl.nu line 107 and results.nu line 40. *)
    let ordered = Schema.StringMap.bindings spec.Schema.services in
    let results : (string, Schema.result_row) Hashtbl.t =
      Hashtbl.create (List.length ordered)
    in
    let results_mutex = Mutex.create () in
    let record name row =
      Mutex.lock results_mutex;
      Hashtbl.replace results name row;
      Mutex.unlock results_mutex
    in
    let run_one ~service_sw (name, svc) =
      wait_service ~sw:service_sw ~env ~handle ~id ~host ~service_name:name
        ~service:svc ~overall_deadline_mono
    in
    let assemble () =
      (* Every fiber writes exactly one row into [results]; names that
       * are missing here indicate a supervisor-level cancellation. In
       * `Throw_first` the first non-Active outcome cancels siblings
       * before they record, so we just drop them. *)
      List.filter_map
        (fun (name, _) -> Hashtbl.find_opt results name)
        ordered
    in
    match strategy with
    | `Collect_all ->
        (* Fork one promise per service; await all. *)
        let promises =
          List.map
            (fun entry ->
              Eio.Fiber.fork_promise ~sw (fun () ->
                  let row = run_one ~service_sw:sw entry in
                  record (fst entry) row;
                  row))
            ordered
        in
        List.iter (fun p -> ignore (Eio.Promise.await p)) promises;
        assemble ()
    | `Throw_first ->
        (* Inner Switch so we can cancel siblings on the first non-
         * Active outcome. Each fiber that hits a terminal non-Active
         * result raises Pctl_error; Switch.run re-raises from the
         * first fiber to fail, cancelling the rest. On success
         * (every fiber Active) the switch drains and we assemble. *)
        Eio.Switch.run (fun inner_sw ->
            List.iter
              (fun entry ->
                Eio.Fiber.fork ~sw:inner_sw (fun () ->
                    let name = fst entry in
                    let row = run_one ~service_sw:inner_sw entry in
                    record name row;
                    match
                      error_of_row row
                        ~overall_timeout_seconds:timeout_seconds
                    with
                    | None -> ()
                    | Some e -> raise (Schema.Pctl_error e)))
              ordered);
        assemble ()
end
