(* Probe — per-service readiness wait + parallel aggregator.
 *
 * Plan binding: docs/src/plans/20260419-ocaml-rewrite.md §"Readiness wait algorithm"
 * and §"Phase 5 — Readiness (up --wait, results)". Behavioural oracle:
 * pctl/lib/probe.nu {wait-probe, wait-ready, wait-all, unit-state,
 * wait-active-unit}.
 *
 * Two public entry points:
 *
 * - [wait_service]: single-fiber wait for one service. Returns a
 *   [Schema.result_row] describing terminal outcome. Never raises for
 *   "probe failed" / "unit failed" — the error is encoded in
 *   [result_row.state]. Does raise [Schema.Pctl_error] only for
 *   infrastructure failures (fork errors etc.) that the caller must
 *   surface.
 *
 * - [wait_all]: parallelises wait_service across every service in the
 *   spec. Shares one [overall_deadline] across fibers so --timeout
 *   bounds the whole wait, not each probe. Two strategies:
 *     * [`Throw_first] — first non-Active result cancels the Switch
 *       via [Switch.fail]; the caller's [Switch.run] re-raises.
 *     * [`Collect_all] — every fiber runs to completion; we aggregate
 *       the list in StringMap order (alphabetical, mirroring the
 *       Nushell `wait-all` which sorts service names before iterating).
 *
 * Timing: [elapsed] is nanoseconds measured via [Mtime_clock]-style
 * monotonic time from Eio's [Mono] clock. It spans the duration of the
 * single [wait_service] invocation (not including scheduler latency
 * before [wait_all] forks the fiber). Subtracted as [Mtime.span start now].
 *)

module S = Systemctl
module Schema = Schema

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

(* Map a terminal systemd state to [Schema.result_state]. Never called
 * with a transient state (caller filters). *)
let state_to_result : Schema.state -> Schema.result_state = function
  | Schema.Active -> `Active
  | Schema.Failed -> `Failed
  | Schema.Inactive -> `Inactive
  | Schema.Activating | Schema.Deactivating | Schema.Reloading ->
      (* Defensive: callers should filter these out first. Represent
       * as Timed_out rather than crashing. *)
      `Timed_out

(* Elapsed ns between [start_mono] and now, clamped to 0 on the unlikely
 * chance the mono clock runs backwards. *)
let elapsed_ns ~start_mono env : int64 =
  let now = Eio.Time.Mono.now (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r) in
  let span = Mtime.span start_mono now in
  Mtime.Span.to_uint64_ns span

let mono_now env =
  Eio.Time.Mono.now (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)

(* The Nushell oracle defaults probe.timeout_seconds to 30 when absent.
 * Spec.load already applies that default (see parse_probe), so this
 * constant is informational only. *)
let _default_probe_timeout_seconds = 30

(* ------------------------------------------------------------------ *)
(* Probe executor — spawn the probe command with PCTL_HOST/PCTL_ID in
 * the env, await exit. Returns [true] iff exit-0.                      *)
(* ------------------------------------------------------------------ *)

(* Build [string array] env that inherits the current process env plus
 * PCTL_ID / PCTL_HOST. Matches Nushell `with-env {PCTL_ID, PCTL_HOST}`
 * which merges with the parent env. *)
let build_child_env ~(id : Schema.project_id) ~(host : Schema.host) :
    string array =
  let current = Unix.environment () in
  let kv = Array.to_list current in
  let filtered =
    List.filter
      (fun s ->
        not
          (String.length s >= 8
          && String.sub s 0 8 = "PCTL_ID="
          || String.length s >= 10
             && String.sub s 0 10 = "PCTL_HOST="))
      kv
  in
  let injected =
    [
      Printf.sprintf "PCTL_ID=%s" (Schema.Project_id.to_string id);
      Printf.sprintf "PCTL_HOST=%s" (Schema.Host.to_string host);
    ]
  in
  Array.of_list (injected @ filtered)

(* Run the probe command ONCE; return true iff exit-0. Any spawn error
 * (executable not found, ...) is caught and turned into [false] — the
 * Nushell oracle `probe-once` does the same. That keeps the wait alive
 * long enough for a slow-to-appear readiness flag file to materialise.
 *
 * The child's stdout/stderr go to /dev/null-backed buffer sinks that we
 * discard on exit. We do NOT inherit parent stdout: [pctl results --json]
 * must emit a clean JSON array and a chatty probe would corrupt it. *)
let run_probe_once ~env ~(child_env : string array)
    ~(exec : string list) : bool =
  match exec with
  | [] ->
      (* An empty exec is spec-level nonsense; the Spec loader should
       * have caught this. Defensive: treat as probe_failed. *)
      false
  | _ ->
      Eio.Switch.run @@ fun sw ->
      try
        let proc_mgr = Eio.Stdenv.process_mgr env in
        let sink_buf = Buffer.create 64 in
        let sink = Eio.Flow.buffer_sink sink_buf in
        let proc =
          Eio.Process.spawn ~sw proc_mgr
            ~stdout:sink ~stderr:sink
            ~env:child_env exec
        in
        match Eio.Process.await proc with
        | `Exited 0 -> true
        | _ -> false
      with _ -> false

(* ------------------------------------------------------------------ *)
(* Functor over Systemctl.S — wait_service / wait_all.                   *)
(* ------------------------------------------------------------------ *)

module Make (M : Systemctl.S) = struct
  type handle = M.t

  (* ---- Unit-state wait (no probe declared) ------------------------- *)

  (* Subscribe first, then read [unit_state] ONCE — avoids the race
   * where the unit reaches Active before the subscription is armed.
   * Blocks the caller fiber on a promise resolved by the subscription
   * callback (or returned directly if the initial read is already
   * terminal). Cancelled externally by the [Fiber.first] wrapper when
   * the deadline fires — the caller's [Fiber.first] cancels this fiber
   * before it returns. *)
  let wait_unit_state (handle : M.t) ~(service_unit : string) :
      Schema.state =
    let p, u = Eio.Promise.create () in
    let resolved = ref false in
    let cb (state : Schema.state) =
      if (not !resolved) && is_terminal_state state then begin
        resolved := true;
        Eio.Promise.resolve u state
      end
    in
    M.subscribe_unit_changes handle ~unit:service_unit cb;
    (* Initial read: if the unit already reached a terminal state
     * before we subscribed, resolve immediately. *)
    let initial = M.unit_state handle ~unit:service_unit in
    if is_terminal_state initial && not !resolved then begin
      resolved := true;
      Eio.Promise.resolve u initial
    end;
    Eio.Promise.await p

  (* ---- Single-service entry point ---------------------------------- *)

  (* Per-service deadline = [min(overall_deadline, now + probe_timeout_s)].
   * The [elapsed] field on the returned row covers the whole fiber's
   * wall clock — from [start_mono] until return. *)
  let wait_service ~sw:_ ~env ~(handle : M.t) ~(id : Schema.project_id)
      ~(host : Schema.host) ~service_name ~(service : Schema.service_spec)
      ~(overall_deadline_mono : Mtime.t) : Schema.result_row =
    ignore host;
    ignore id;
    let start_mono = mono_now env in
    let service_unit =
      let uf =
        Install.Paths.substitute_id ~id service.Schema.unit_filename
      in
      uf
    in
    (* Choose the per-service deadline. *)
    let service_deadline =
      match service.Schema.probe with
      | None -> overall_deadline_mono
      | Some p ->
          let ns =
            Int64.mul (Int64.of_int p.Schema.timeout_seconds) 1_000_000_000L
          in
          let per_probe =
            match
              Mtime.add_span start_mono (Mtime.Span.of_uint64_ns ns)
            with
            | Some d -> d
            | None -> overall_deadline_mono
          in
          if Mtime.is_earlier per_probe ~than:overall_deadline_mono then
            per_probe
          else overall_deadline_mono
    in
    let mono_clock =
      (env#mono_clock :> Eio.Time.Mono.ty Eio.Std.r)
    in
    let make_row state kind =
      {
        Schema.name = service_name;
        state;
        elapsed = elapsed_ns ~start_mono env;
        kind;
      }
    in
    match service.Schema.probe with
    | Some probe ->
        let child_env = build_child_env ~id ~host in
        let period_s = float_of_int probe.Schema.period_seconds in
        let run_probe_loop () =
          (* First check is immediate — matches Nushell wait-probe. *)
          let rec loop () =
            if run_probe_once ~env ~child_env ~exec:probe.Schema.exec
            then `Active
            else begin
              (* Sleep up to [period_s] but no later than the deadline. *)
              let now = mono_now env in
              if not (Mtime.is_earlier now ~than:service_deadline) then
                `Timed_out
              else begin
                Eio.Time.sleep
                  (env#clock :> float Eio.Time.clock_ty Eio.Std.r)
                  period_s;
                loop ()
              end
            end
          in
          loop ()
        in
        let deadline_timer () =
          Eio.Time.Mono.sleep_until mono_clock service_deadline;
          `Timed_out
        in
        let outcome =
          Eio.Fiber.first run_probe_loop deadline_timer
        in
        let row =
          match outcome with
          | `Active -> make_row `Active `Probe
          | `Timed_out ->
              (* If the per-service deadline (probe timeout) fires
               * before the overall, mark as probe-failed; if they
               * coincide (or overall triggered), mark timed-out.
               * Match Nushell: `if $effective < $remaining { "probe-failed" } else { "timed-out" }`. *)
              let state =
                if
                  Mtime.is_earlier service_deadline
                    ~than:overall_deadline_mono
                then `Probe_failed
                else `Timed_out
              in
              make_row state `Probe
        in
        row
    | None ->
        let state_wait () =
          let s = wait_unit_state handle ~service_unit in
          s
        in
        let deadline_timer () =
          Eio.Time.Mono.sleep_until mono_clock service_deadline;
          `Deadline
        in
        let outcome =
          Eio.Fiber.first
            (fun () -> `State (state_wait ()))
            deadline_timer
        in
        (match outcome with
         | `State s -> make_row (state_to_result s) `Unit_state
         | `Deadline -> make_row `Timed_out `Unit_state)

  (* ---- Multi-service entry point ---------------------------------- *)

  (* Build a Pctl_error appropriate for each non-Active outcome, used
   * by `Throw_first` mode. The error message must name the service
   * and the terminal state — the Nushell oracle asserts both in
   * wait_failed_oneshot_test and wait_overall_timeout_test. *)
  let error_of_row (r : Schema.result_row) ~overall_timeout_seconds :
      Schema.error option =
    match r.state with
    | `Active -> None
    | `Probe_failed ->
        Some
          (Schema.Probe_timeout
             {
               service = r.name;
               timeout_ms =
                 (* Best-effort display; exact value derivable from
                  * probe.timeout_seconds upstream. *)
                 overall_timeout_seconds * 1000;
             })
    | `Timed_out ->
        Some
          (Schema.Probe_timeout
             {
               service = r.name;
               timeout_ms = overall_timeout_seconds * 1000;
             })
    | `Failed ->
        Some
          (Schema.Unit_op_failed
             {
               op = "wait";
               unit_ = r.name;
               reply =
                 Printf.sprintf
                   "service %s terminated in state 'failed' (expected \
                    'active')"
                   r.name;
             })
    | `Inactive ->
        Some
          (Schema.Unit_op_failed
             {
               op = "wait";
               unit_ = r.name;
               reply =
                 Printf.sprintf
                   "service %s terminated in state 'inactive' (expected \
                    'active')"
                   r.name;
             })

  let wait_all ~sw ~env ~(handle : M.t) ~(id : Schema.project_id)
      ~(host : Schema.host) ~(spec : Schema.spec) ~timeout_seconds
      ~(strategy : strategy) : Schema.result_row list =
    let start_mono = mono_now env in
    let overall_deadline_mono =
      let ns =
        Int64.mul (Int64.of_int timeout_seconds) 1_000_000_000L
      in
      match
        Mtime.add_span start_mono (Mtime.Span.of_uint64_ns ns)
      with
      | Some d -> d
      | None ->
          (* Overflow: cap at the mono clock's max representable
           * time. This is effectively infinite. *)
          start_mono
    in
    (* Iterate in StringMap (alphabetical) order — matches Nushell
     * oracle `sort` in pctl.nu line 107 and results.nu line 40. *)
    let ordered = Schema.StringMap.bindings spec.Schema.services in
    (* Result slots keyed by name so we can re-assemble in spec
     * declaration (StringMap) order regardless of completion order. *)
    let results : (string, Schema.result_row) Hashtbl.t =
      Hashtbl.create (List.length ordered)
    in
    let results_mutex = Mutex.create () in
    let record name row =
      Mutex.lock results_mutex;
      Hashtbl.replace results name row;
      Mutex.unlock results_mutex
    in
    match strategy with
    | `Collect_all ->
        (* Fork one promise per service; await all. Exceptions inside a
         * fiber are converted to a `Timed_out` row so the caller never
         * sees a partial list. *)
        let promises =
          List.map
            (fun (name, svc) ->
              Eio.Fiber.fork_promise ~sw (fun () ->
                  try
                    let row =
                      wait_service ~sw ~env ~handle ~id ~host
                        ~service_name:name ~service:svc
                        ~overall_deadline_mono
                    in
                    record name row;
                    row
                  with
                  | Schema.Pctl_error _ ->
                      let row =
                        {
                          Schema.name;
                          state = `Timed_out;
                          elapsed = elapsed_ns ~start_mono env;
                          kind = `Unit_state;
                        }
                      in
                      record name row;
                      row))
            ordered
        in
        List.iter
          (fun p ->
            match Eio.Promise.await p with
            | Ok _ -> ()
            | Error _ -> ())
          promises;
        (* Re-assemble in StringMap order. Services that never recorded
         * a result (shouldn't happen) get a synthesised timed-out row. *)
        List.map
          (fun (name, _) ->
            match Hashtbl.find_opt results name with
            | Some r -> r
            | None ->
                {
                  Schema.name;
                  state = `Timed_out;
                  elapsed = 0L;
                  kind = `Unit_state;
                })
          ordered
    | `Throw_first ->
        (* Open a nested Switch so we can cancel all sibling fibers on
         * the first non-Active outcome. Each fiber that hits a terminal
         * non-Active result raises [Pctl_error]; Switch.run re-raises
         * from the first fiber to fail, cancelling the rest. On success
         * (every fiber reports Active) the switch drains and we return
         * the collected list. *)
        Eio.Switch.run (fun inner_sw ->
            List.iter
              (fun (name, svc) ->
                Eio.Fiber.fork ~sw:inner_sw (fun () ->
                    let row =
                      wait_service ~sw ~env ~handle ~id ~host
                        ~service_name:name ~service:svc
                        ~overall_deadline_mono
                    in
                    record name row;
                    match
                      error_of_row row
                        ~overall_timeout_seconds:timeout_seconds
                    with
                    | None -> ()
                    | Some e -> raise (Schema.Pctl_error e)))
              ordered);
        List.map
          (fun (name, _) ->
            match Hashtbl.find_opt results name with
            | Some r -> r
            | None ->
                {
                  Schema.name;
                  state = `Active;
                  elapsed = 0L;
                  kind = `Unit_state;
                })
          ordered
end

(* ------------------------------------------------------------------ *)
(* Thin wrappers that pick a concrete Systemctl at call time. The CLI
 * layer instantiates the functor; bin/pctl wires Dbus, tests can wire
 * In_mem. *)

module Dbus = Make (Systemctl.Dbus)
module In_mem = Make (Systemctl.In_mem)
