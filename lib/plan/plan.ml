(* Plan — the pure reload diff and its "+ / ~ / = / -" renderings.
 *
 * [diff ~installed ~rendered]: [installed] is what user.control holds for
 * the units this project owns, read per invocation; [rendered] is what
 * the current spec renders to. No I/O, no port dependency. *)

open Schema

module UfMap = Map.Make (Schema.Unit_filename)

let diff ~(installed : unit_hashes) ~(rendered : unit_hashes) : plan_row list =
  let of_list l = List.fold_left (fun acc (k, v) -> UfMap.add k v acc) UfMap.empty l in
  let installed_m = of_list installed and rendered_m = of_list rendered in
  UfMap.merge
    (fun unit_ old_hash new_hash ->
      let row action = Some { unit_; action; old_hash; new_hash } in
      match (old_hash, new_hash) with
      | None, None -> None
      | None, Some _ -> row Added
      | Some _, None -> row Removed
      | Some a, Some b when a = b -> row Unchanged
      | Some _, Some _ -> row Changed)
    installed_m rendered_m
  |> UfMap.bindings |> List.map snd

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

let count_by action rows =
  List.fold_left (fun n r -> if r.action = action then n + 1 else n) 0 rows

let counts rows =
  Printf.sprintf "+%d ~%d =%d -%d"
    (count_by Added rows)
    (count_by Changed rows)
    (count_by Unchanged rows)
    (count_by Removed rows)
