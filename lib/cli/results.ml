(* Results — `pctl results [--timeout SECS] [--json] [--path DIR]`.
 *
 * Oracle: the prior Nushell `results` command. Behaviour:
 *   1. Resolve project path + id.
 *   2. Open DB, session-reset, load the project row.
 *   3. Re-load the spec from the row's [store_tree] (the spec.json
 *      emitted by Nix and persisted at `up` time). If that path is
 *      missing, we degrade gracefully to a no-probe wait — matches
 *      the Nushell's "falling back to unit-state polling" branch.
 *   4. Probe.wait_all ~strategy:`Collect_all ~timeout_seconds.
 *   5. Print either JSON (byte-compatible with tuor's
 *      scripts/collect-pctl-artifacts.nu) or a plain-text summary.
 *
 * Exit code: propagates from run_with_errors. The worst non-Active
 * result_row drives the exit value:
 *   - any `Failed` state   -> Unit_op_failed  (bucket 5)
 *   - any `Inactive`       -> Unit_op_failed  (bucket 5)
 *   - any `Probe_failed`   -> Probe_timeout   (bucket 6)
 *   - any `Timed_out`      -> Probe_timeout   (bucket 6)
 * Otherwise 0.
 *)

open Common

(* Find the worst state in the list (for exit code purposes). Ordering
 * (worst to best): Failed > Inactive > Probe_failed > Timed_out > Active.
 * If every row is Active, returns None. *)
let worst_row (rows : Schema.result_row list) : Schema.result_row option =
  let rank : Schema.result_state -> int = function
    | `Active -> 0
    | `Timed_out -> 1
    | `Probe_failed -> 2
    | `Inactive -> 3
    | `Failed -> 4
  in
  List.fold_left
    (fun acc r ->
      match acc with
      | None when r.Schema.state = `Active -> None
      | None -> Some r
      | Some cur ->
          if rank r.Schema.state > rank cur.Schema.state then Some r
          else acc)
    None rows

let error_of_row (r : Schema.result_row) ~timeout_seconds : Schema.error =
  match r.Schema.state with
  | `Active ->
      (* Shouldn't happen — caller gates on non-Active. Fall back to a
       * generic error to be safe. *)
      Schema.Probe_timeout
        { service = r.name; timeout_ms = timeout_seconds * 1000 }
  | `Probe_failed | `Timed_out ->
      Schema.Probe_timeout
        { service = r.name; timeout_ms = timeout_seconds * 1000 }
  | `Failed ->
      Schema.Unit_op_failed
        {
          op = "wait";
          unit_ = r.name;
          reply =
            Printf.sprintf
              "service %s terminated in state 'failed' (expected 'active')"
              r.name;
        }
  | `Inactive ->
      Schema.Unit_op_failed
        {
          op = "wait";
          unit_ = r.name;
          reply =
            Printf.sprintf
              "service %s terminated in state 'inactive' (expected \
               'active')"
              r.name;
        }

let format_human (rows : Schema.result_row list) : string =
  (* Fixed-column plain text for grep-friendly output (mirrors Nushell
   * results.nu:67-69: state pad 12, elapsed pad 10). Elapsed is emitted
   * as "<N>ns" so `nu` / humans can parse it with `into duration`. *)
  let buf = Buffer.create 128 in
  List.iter
    (fun (r : Schema.result_row) ->
      let state = Schema.result_state_to_string r.Schema.state in
      let pad s w =
        let n = String.length s in
        if n >= w then s else s ^ String.make (w - n) ' '
      in
      Buffer.add_string buf
        (Printf.sprintf "%s  %s  %s\n" (pad state 12)
           (pad (Printf.sprintf "%Lins" r.Schema.elapsed) 10)
           r.Schema.name))
    rows;
  Buffer.contents buf

let format_json (rows : Schema.result_row list) : string =
  let j : Yojson.Safe.t =
    `List (List.map Schema.result_row_to_yojson rows)
  in
  Yojson.Safe.to_string j

(* See notes in Cli.Up — scope the Dbus connection and its dispatch
 * fiber to an inner Switch so cleanup runs inside an Eio-handled
 * context. *)
let run_wait_all ~env ~sw:_ ~id ~host ~spec ~timeout_seconds :
    Schema.result_row list =
  Eio.Switch.run (fun inner_sw ->
      let t = Systemctl.Dbus.connect ~sw:inner_sw env in
      let rows =
        Probe_dbus.wait_all ~sw:inner_sw ~env ~handle:t ~id ~host
          ~spec ~timeout_seconds ~strategy:`Collect_all
      in
      Systemctl.Dbus.close t;
      rows)

(* Resolve the spec.json to use for readiness. We pull it directly from
 * the [projects.spec_json] blob persisted at up/reload time — the
 * on-disk store_tree may have been garbage-collected since, but the
 * DB blob is session-scoped and cleared by [Session.reset] at the next
 * boot, so the bytes here always match the running services. *)
let spec_for_results (conn : State.Db.t) ~project_id_s : Schema.spec =
  match State.Projects.get_by_id conn ~id:project_id_s with
  | None | Some { spec_json = None | Some ""; _ } ->
      raise
        (Schema.Pctl_error
           (Schema.Registry_io
              {
                id = project_id_s;
                reason = "project is not registered — run `pctl up` first";
              }))
  | Some { spec_json = Some blob; _ } ->
      Spec.parse ~path:(project_id_s ^ ":spec_json")
        (Yojson.Safe.from_string blob)

let run ~sw ~env ?path ?(timeout = 600) ?(json = false) () : int =
  run_with_errors (fun () ->
      let project_path = resolve_path path in
      let id = Identity.derive ~path:project_path in
      let project_id_s = Schema.Project_id.to_string id in
      with_connection ~env ~sw (fun conn ->
          (* Resolve host from the persistent project row. *)
          let row = State.Projects.get_by_id conn ~id:project_id_s in
          let host =
            match row with
            | Some { host = Some h; _ } -> (
                match Schema.Host.of_string_opt h with
                | Some h -> h
                | None ->
                    raise
                      (Schema.Pctl_error
                         (Schema.Registry_io
                            {
                              id = project_id_s;
                              reason =
                                Printf.sprintf
                                  "project host '%s' is not a valid \
                                   127.0.0.N"
                                  h;
                            })))
            | _ ->
                raise
                  (Schema.Pctl_error
                     (Schema.Registry_io
                        {
                          id = project_id_s;
                          reason =
                            "project is not registered — run `pctl up` \
                             first";
                        }))
          in
          let spec = spec_for_results conn ~project_id_s in
          let rows =
            run_wait_all ~env ~sw ~id ~host ~spec ~timeout_seconds:timeout
          in
          let out =
            if json then format_json rows ^ "\n" else format_human rows
          in
          print_string out;
          (* Exit non-zero if any row is not Active. *)
          match worst_row rows with
          | None -> ()
          | Some r -> raise (Schema.Pctl_error (error_of_row r ~timeout_seconds:timeout))))
