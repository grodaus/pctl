(* Plan — pure formatter for the diff rendering column.
 *
 * Historically this module also owned the Systemctl application logic
 * (the [Make] functor), but phase 5 of the Lifecycle consolidation
 * absorbed [apply_row] / [apply] into [Lifecycle.Make]. What stays
 * here is only the "+ / ~ / = / -" summary string used by
 * [pctl reload] output — pure, no I/O, no port dependency. *)

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
