(* Plan — diff the old manifest against the new, print a summary,
 * and apply the plan via the Systemctl port.
 *
 * Oracle: the prior Nushell `reload` command for the ordering and action
 * semantics; the Nushell `manifest summary` helper for the
 * "+<a> ~<c> =<u> -<r>" line.
 *
 * Apply semantics (from the plan brief + the Nushell reload oracle):
 *   - Added/Changed services  -> start_unit / restart_unit (started for
 *     Added, restarted for Changed to bounce state).
 *   - Removed services        -> stop_unit (tolerated failure: systemd
 *     may have already GCed the unit after file deletion).
 *   - Unchanged               -> skip.
 *   - Slice row: started if Added, untouched if Changed/Unchanged/Removed.
 *     Nushell `reload` skips slice-level actions on purpose — bouncing
 *     a slice restarts every service under it. We preserve that here.
 *   - After all operations: daemon_reload ONCE.
 *
 * Order (per brief): slice first, then services in sorted unit_filename
 * order. `Manifest.diff` already produces sorted-by-unit_filename output,
 * so we just pick slice rows out, then the rest.
 *
 * For the detailed "+ name" listing see [render_summary]. *)

let is_slice_unit (r : Schema.plan_row) : bool =
  let s = Schema.Unit_filename.to_string r.unit_ in
  let n = String.length s in
  n >= 6 && String.sub s (n - 6) 6 = ".slice"

let sort_rows rows =
  (* Stable, lexicographic on unit_filename. *)
  List.sort
    (fun (a : Schema.plan_row) (b : Schema.plan_row) ->
      Schema.Unit_filename.compare a.unit_ b.unit_)
    rows

let render_summary (rows : Schema.plan_row list) : string =
  let rows = sort_rows rows in
  let buf = Buffer.create 256 in
  List.iter
    (fun (r : Schema.plan_row) ->
      Buffer.add_string buf
        (Printf.sprintf "%s %s\n"
           (Schema.action_to_symbol r.action)
           (Schema.Unit_filename.to_string r.unit_)))
    rows;
  Buffer.contents buf

module Make (M : Systemctl.S) = struct
  let apply_row (t : M.t) (r : Schema.plan_row) : unit =
    let unit_s = Schema.Unit_filename.to_string r.unit_ in
    match r.action with
    | Schema.Unchanged -> ()
    | Schema.Added ->
        (* Start — works for both slice and service rows. *)
        M.start_unit t ~unit:unit_s
    | Schema.Changed ->
        if is_slice_unit r then
          (* See oracle: reload.nu skips slice-level actions (restarting
           * a slice bounces every service under it). *)
          ()
        else
          M.restart_unit t ~unit:unit_s
    | Schema.Removed ->
        (* Tolerate failure: systemd may report NoSuchUnit after the
         * unit file has been deleted. A failed stop shouldn't abort
         * the reload — matches the Nushell reload oracle. *)
        (try M.stop_unit t ~unit:unit_s
         with Schema.Pctl_error _ -> ())

  (* daemon_reload first (so systemd sees new/updated unit files on disk
   * before we attempt to start them), then operate on rows, then a final
   * daemon_reload so removed files are forgotten by systemd. Oracle:
   * the prior Nushell `up` command reloaded before start; the prior
   * Nushell `down` reloaded after the stop + delete. Doing both here
   * satisfies every caller — an extra reload is cheap and always correct. *)
  let apply ~(handle : M.t) ~(rows : Schema.plan_row list) : unit =
    let rows = sort_rows rows in
    M.daemon_reload handle;
    let slices, services = List.partition is_slice_unit rows in
    List.iter (apply_row handle) slices;
    List.iter (apply_row handle) services;
    M.daemon_reload handle
end
