(* Manifest diff — ported from pctl/lib/manifest.nu:1-19.
 *
 * Phase 1 ships only the pure diff; SQLite plumbing lands in Phase 2. *)

open Schema

let diff ~(before : manifest) ~(after : manifest) : plan_row list =
  let module M = StringMap in
  let before_m =
    List.fold_left (fun acc (k, v) -> M.add k v acc) M.empty before
  in
  let after_m =
    List.fold_left (fun acc (k, v) -> M.add k v acc) M.empty after
  in
  let keys =
    M.merge
      (fun _ a b -> match (a, b) with None, None -> None | _ -> Some ())
      before_m after_m
  in
  M.bindings keys
  |> List.map (fun (unit_, ()) ->
         let old_hash = M.find_opt unit_ before_m in
         let new_hash = M.find_opt unit_ after_m in
         let action =
           match (old_hash, new_hash) with
           | None, Some _ -> Added
           | Some _, None -> Removed
           | Some a, Some b when a = b -> Unchanged
           | Some _, Some _ -> Changed
           | None, None -> assert false
         in
         { unit_; action; old_hash; new_hash })

let count_by action rows =
  List.fold_left (fun n r -> if r.action = action then n + 1 else n) 0 rows

let summary rows =
  Printf.sprintf "+%d ~%d =%d -%d"
    (count_by Added rows)
    (count_by Changed rows)
    (count_by Unchanged rows)
    (count_by Removed rows)
