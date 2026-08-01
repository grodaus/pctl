(* Gc — opportunistic sweep on mutating commands + explicit purge.
 *
 * Class derivation (reconciled with [State.Session.reset]):
 *   Unknown  — path no longer exists on disk
 *   Live     — session_id = current boot_id (row is from this session)
 *   Orphan   — otherwise (session_id NULL after session reset, path exists)
 *
 * Boot id via [Clock.read_boot_id_exn], never the degrading reader: "" can
 * never satisfy the Live guard, so gc would delete everything (pctl-2jn).
 *
 * Note: the alternative derivation "Orphan iff session_id != current
 * boot_id" never fires: [Session.reset] NULLs every stale session_id at
 * connection open, so by the time Gc sees a row the stale path is always
 * the "path exists but session_id is NULL" branch.
 *
 * Opportunistic sweep semantics:
 *   - Env guard PCTL_NO_GC=1 returns immediately, BEFORE any DB work.
 *   - Callers invoke [opportunistic_sweep] as the first op inside
 *     [Pipeline.with_connection], so session reset has already run. A
 *     path that "no longer exists" is classified as Unknown; Unknown
 *     rows with no live session get their units removed + row deleted.
 *   - Failures warn to stderr and return unit; never abort the outer
 *     command (warn-and-proceed).
 *
 * Explicit purge (`pctl gc --yes`):
 *   - Sweeps every non-Live project. Prints one line per removed id.
 *   - Exit 0 on success; stderr-warn-and-proceed on per-row failure.
 *     Returns the first Pctl_error-worthy error code only if nothing
 *     else succeeded.
 *
 * Stop failure policy (shared by both, see [stop_or_propagate]):
 *   - stop_unit tolerates ONLY a no-such-unit reply. Every other stop
 *     failure means systemd did not even accept the stop job, so the
 *     cgroup cascade cannot have fired and the services are still
 *     running; it propagates out of [remove_project] BEFORE the unit
 *     files are deleted.
 *   - Both entry points iterate row by row, so a propagated failure
 *     skips that one project — its units, manifest and registry row all
 *     survive for a later retry — and the remaining projects are still
 *     swept.
 *)

let no_gc_env () : bool =
  match Sys.getenv_opt "PCTL_NO_GC" with Some "1" -> true | _ -> false

let class_of_row ~(boot_id : string) (row : State.Projects.t) : Schema.class_ =
  if not (Sys.file_exists row.path) then Schema.Unknown
  else
    match row.session_id with
    | Some s when s = boot_id && s <> "" -> Schema.Live
    | _ -> Schema.Orphan

(* [Printexc.to_string] renders a Pctl_error as "Pctl_error(_)". The
 * per-row warning is the only report a skipped project gets, so it has
 * to name the actual failure. *)
let describe_exn = function
  | Schema.Pctl_error e -> Schema.render_error e
  | e -> Printexc.to_string e

(* Remove every unit file and drop-in for [row] from user.control and
 * stop the matching units on [handle]. Raises if a unit could not be
 * stopped; tolerates every other failure and logs to stderr so the user
 * sees progress. *)
module Make (M : Systemctl.S) = struct
  (* Catches used for the file/DB steps of remove_project — those MUST
   * be best-effort; a stale row with no units on disk shouldn't block
   * removal of the DB row. We still narrow from [_] to the specific
   * failure modes we've observed: systemd not running (Unix_error),
   * pctl-tracked errors (Pctl_error), and caqti wrappers (Failure).
   * The stops are NOT in this bucket — see [stop_or_propagate]. *)
  let ignore_best_effort f =
    try f ()
    with Failure _ | Unix.Unix_error _ | Schema.Pctl_error _ -> ()

  (* Only a no-such-unit reply is tolerated: nothing is loaded, so there
   * is nothing to cascade and nothing left running. Any other failure
   * propagates so [remove_project] aborts before deleting the unit
   * files — deleting them when systemd would not even accept the stop
   * leaves the processes alive in a cgroup with no units left to manage
   * them, invisible to [pctl status] and unreachable by [pctl down] or
   * a second [pctl gc].
   *
   * Measured under pctl-8sd on systemd 257: Manager.StopUnit on an
   * unloaded .service answers NoSuchUnit, but on an unloaded .slice it
   * SUCCEEDS (systemd synthesises fragment-less slices). So on this
   * version the tolerated branch is reachable for the per-service stops
   * below and not for the slice stop; it is kept for both as the
   * documented intent, and exercised through the fake. *)
  let stop_or_propagate (handle : M.t) ~(unit_ : string) : unit =
    try M.stop_unit handle ~unit:unit_
    with Schema.Pctl_error e when Schema.is_no_such_unit e -> ()

  let remove_project ~(conn : State.Db.t) ~(handle : M.t)
      (row : State.Projects.t) : unit =
    let id_s = row.id in
    let id = Schema.Project_id.of_string_exn id_s in
    (* Load the stored manifest so we stop + delete the right unit files. *)
    let manifest =
      try State.Projects.load_manifest conn ~project_id:id_s
      with Failure _ | Schema.Pctl_error _ -> []
    in
    let slice_unit =
      Schema.Unit_filename.to_string (Schema.Unit_filename.slice ~id)
    in
    stop_or_propagate handle ~unit_:slice_unit;
    List.iter
      (fun (uf, _) ->
        stop_or_propagate handle ~unit_:(Schema.Unit_filename.to_string uf))
      manifest;
    (* Best-effort from here on. Note what the stops above do and do not
     * establish: [call_unit_op] is a bare Manager.StopUnit(name,
     * "replace") (dbus.ml:519-529), so a successful return means systemd
     * ACCEPTED the stop job, not that the processes are gone. This is
     * the ordering the down path already relies on; narrowing the catch
     * only removes the case where the job was never accepted at all. A
     * stale systemd view is recovered by the next daemon-reload. *)
    ignore_best_effort (fun () -> M.daemon_reload handle);
    (* Remove the actual unit files on disk. Unit_store.Fs.remove
     * tolerates non-existence already. *)
    ignore_best_effort (fun () ->
        let us = Unit_store.Fs.create () in
        List.iter
          (fun (uf, _) -> Unit_store.Fs.remove us ~unit_:uf)
          manifest;
        (* Defensive: some earlier paths did not persist the slice in
         * the manifest. Removing it again is a no-op. *)
        Unit_store.Fs.remove us ~unit_:(Schema.Unit_filename.slice ~id));
    ignore_best_effort (fun () -> M.daemon_reload handle);
    (* Wipe the manifest + project row. *)
    ignore_best_effort (fun () ->
        State.Projects.replace_manifest conn ~project_id:id_s ~rows:[]);
    ignore_best_effort (fun () ->
        State.Projects.delete_by_id conn ~id:id_s)

  (* Opportunistic sweep — called at the top of up/reload/down/restart
   * (inside with_connection). Iterates every project and removes those
   * whose class is Unknown (path no longer exists). Orphan rows are
   * left alone — the user may still want to `pctl up` a fresh checkout
   * of the same path, and we don't want to nuke their stored host. *)
  let opportunistic_sweep ~(conn : State.Db.t) ~(handle : M.t) : unit =
    if no_gc_env () then ()
    else
      try
        let boot_id = Clock.read_boot_id_exn () in
        let rows = State.Projects.all conn in
        List.iter
          (fun row ->
            match class_of_row ~boot_id row with
            | Schema.Unknown -> (
                try remove_project ~conn ~handle row
                with e ->
                  Printf.eprintf
                    "pctl gc: warn — failed to sweep %s: %s\n" row.id
                    (describe_exn e))
            | Schema.Orphan | Schema.Live -> ())
          rows
      with e ->
        Printf.eprintf "pctl gc: warn — sweep aborted: %s\n" (describe_exn e)

  (* Explicit purge — `pctl gc --yes`. Removes every non-Live project
   * row. Returns the number of projects removed. Prints one "removed
   * <id>" line per row (stdout) so the user can see progress. *)
  let purge ~(conn : State.Db.t) ~(handle : M.t) : int =
    let boot_id = Clock.read_boot_id_exn () in
    let rows = State.Projects.all conn in
    List.fold_left
      (fun removed row ->
        match class_of_row ~boot_id row with
        | Schema.Live -> removed
        | Schema.Orphan | Schema.Unknown -> (
            try
              remove_project ~conn ~handle row;
              Printf.printf "removed %s\n" row.id;
              removed + 1
            with e ->
              Printf.eprintf "pctl gc: warn — failed to remove %s: %s\n"
                row.id (describe_exn e);
              removed))
      0 rows
end

(* Report-only (no --yes) classification output — one row per project.
 * Caller prints; no systemctl handle needed. *)
let report ~(conn : State.Db.t) : (State.Projects.t * Schema.class_) list =
  let boot_id = Clock.read_boot_id_exn () in
  State.Projects.all conn
  |> List.map (fun row -> (row, class_of_row ~boot_id row))
