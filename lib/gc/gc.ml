(* Gc — opportunistic sweep on mutating commands + explicit purge.
 *
 * Class derivation (reconciled with [State.Session.reset]):
 *   Unknown  — path no longer exists on disk
 *   Live     — session_id = current boot_id (row is from this session)
 *   Orphan   — otherwise (session_id NULL after session reset, path exists)
 *
 * Note: the alternative derivation "Orphan iff session_id != current
 * boot_id" never fires: [Session.reset] NULLs every stale session_id at
 * connection open, so by the time Gc sees a row the stale path is always
 * the "path exists but session_id is NULL" branch.
 *
 * Opportunistic sweep semantics:
 *   - Env guard PCTL_NO_GC=1 returns immediately, BEFORE any DB work.
 *   - Callers invoke [opportunistic_sweep] as the first op inside
 *     [Common.with_connection], so session reset has already run. A
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
 *)

let no_gc_env () : bool =
  match Sys.getenv_opt "PCTL_NO_GC" with Some "1" -> true | _ -> false

let current_boot_id () : string =
  try State.Session.read_boot_id () with _ -> ""

let class_of_row ~(boot_id : string) (row : State.Projects.t) : Schema.class_ =
  if not (Sys.file_exists row.path) then Schema.Unknown
  else
    match row.session_id with
    | Some s when s = boot_id && s <> "" -> Schema.Live
    | _ -> Schema.Orphan

(* Remove every unit file and drop-in for [row] from user.control and
 * stop the matching units on [handle]. Tolerates every failure; logs
 * to stderr so the user sees progress. *)
module Make (M : Systemctl.S) = struct
  (* Catches used throughout remove_project — gc sweeps MUST be
   * best-effort; a stale row with no units on disk shouldn't block
   * removal of the DB row. We still narrow from [_] to the specific
   * failure modes we've observed: systemd not running (Unix_error),
   * pctl-tracked errors (Pctl_error), and caqti wrappers (Failure). *)
  let ignore_best_effort f =
    try f ()
    with Failure _ | Unix.Unix_error _ | Schema.Pctl_error _ -> ()

  let remove_project ~(conn : State.Db.t) ~(handle : M.t)
      (row : State.Projects.t) : unit =
    let id_s = row.id in
    (* Load the stored manifest so we stop + delete the right unit files. *)
    let manifest =
      try State.Projects.load_manifest conn ~project_id:id_s
      with Failure _ | Schema.Pctl_error _ -> []
    in
    let slice_unit = Printf.sprintf "pctl-%s.slice" id_s in
    ignore_best_effort (fun () -> M.stop_unit handle ~unit:slice_unit);
    List.iter
      (fun (uf, _) ->
        ignore_best_effort (fun () -> M.stop_unit handle ~unit:uf))
      manifest;
    ignore_best_effort (fun () -> M.daemon_reload handle);
    (* Remove the actual unit files on disk. [remove_units] is tolerant
     * of non-existence already. *)
    ignore_best_effort (fun () ->
        let filenames = List.map fst manifest in
        Install.Install.remove_units filenames;
        (* Also try to remove the slice file — some paths through the
         * codebase store the slice in the manifest, but be defensive. *)
        Install.Install.remove_units [ Printf.sprintf "pctl-%s.slice" id_s ]);
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
        let boot_id = current_boot_id () in
        let rows = State.Projects.all conn in
        List.iter
          (fun row ->
            match class_of_row ~boot_id row with
            | Schema.Unknown -> (
                try remove_project ~conn ~handle row
                with e ->
                  Printf.eprintf
                    "pctl gc: warn — failed to sweep %s: %s\n" row.id
                    (Printexc.to_string e))
            | Schema.Orphan | Schema.Live -> ())
          rows
      with e ->
        Printf.eprintf "pctl gc: warn — sweep aborted: %s\n"
          (Printexc.to_string e)

  (* Explicit purge — `pctl gc --yes`. Removes every non-Live project
   * row. Returns the number of projects removed. Prints one "removed
   * <id>" line per row (stdout) so the user can see progress. *)
  let purge ~(conn : State.Db.t) ~(handle : M.t) : int =
    let boot_id = current_boot_id () in
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
                row.id (Printexc.to_string e);
              removed))
      0 rows
end

(* Report-only (no --yes) classification output — one row per project.
 * Caller prints; no systemctl handle needed. *)
let report ~(conn : State.Db.t) : (State.Projects.t * Schema.class_) list =
  let boot_id = current_boot_id () in
  State.Projects.all conn
  |> List.map (fun row -> (row, class_of_row ~boot_id row))
