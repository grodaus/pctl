(* Projects — CRUD over the `projects` table, plus the `manifest` table
 * and the pure manifest-diff.
 *
 * Project row shape (migrations/001_init.sql):
 *   id           TEXT PRIMARY KEY
 *   path         TEXT NOT NULL
 *   host         TEXT
 *   started_at   TEXT
 *   store_tree   TEXT
 *   session_id   TEXT
 *
 * Manifest row shape:
 *   project_id      TEXT
 *   unit_filename   TEXT
 *   sha256          TEXT
 *
 * All functions raise [Schema.Pctl_error (Registry_io ...)] on caqti
 * failure — consumers catch once in bin/pctl.ml. *)

open Caqti_request.Infix
open Caqti_type.Std

type t = {
  id : string;
  path : string;
  host : string option;
  started_at : string option;
  store_tree : string option;
  session_id : string option;
}

let row_type =
  (* id, path, host, started_at, store_tree, session_id *)
  t6 string string (option string) (option string) (option string)
    (option string)

let to_row r =
  (r.id, r.path, r.host, r.started_at, r.store_tree, r.session_id)

let of_row (id, path, host, started_at, store_tree, session_id) =
  { id; path; host; started_at; store_tree; session_id }

(* Upsert: INSERT OR on-conflict update. Keeps id/path stable; other
 * columns are overwritten (they are session-scoped and reset by
 * [Session.reset] at a different boot). *)
let upsert_req =
  (row_type ->. unit)
    "INSERT INTO projects \
       (id, path, host, started_at, store_tree, session_id) \
     VALUES (?, ?, ?, ?, ?, ?) \
     ON CONFLICT(id) DO UPDATE SET \
       path       = excluded.path, \
       host       = excluded.host, \
       started_at = excluded.started_at, \
       store_tree = excluded.store_tree, \
       session_id = excluded.session_id"

let get_by_id_req =
  (string ->? row_type)
    "SELECT id, path, host, started_at, store_tree, session_id \
     FROM projects WHERE id = ?"

let get_by_path_req =
  (string ->? row_type)
    "SELECT id, path, host, started_at, store_tree, session_id \
     FROM projects WHERE path = ?"

let all_req =
  (unit ->* row_type)
    "SELECT id, path, host, started_at, store_tree, session_id \
     FROM projects ORDER BY id"

let delete_by_id_req =
  (string ->. unit)
    "DELETE FROM projects WHERE id = ?"

(* Null out session-scoped columns but keep the row (path + id stay).
 * Used by `pctl down` — it preserves the registry entry (so `gc` can
 * decide when to delete entirely) but marks the project as no-longer-
 * running. *)
let clear_runtime_fields_req =
  (string ->. unit)
    "UPDATE projects \
     SET host = NULL, started_at = NULL, store_tree = NULL, session_id = NULL \
     WHERE id = ?"

let raise_io ~id (e : [> Caqti_error.t ]) =
  raise
    (Schema.Pctl_error
       (Schema.Registry_io { id; reason = Caqti_error.show e }))

let upsert ((module C : Caqti_eio.CONNECTION)) (r : t) : unit =
  match C.exec upsert_req (to_row r) with
  | Ok () -> ()
  | Error e -> raise_io ~id:r.id e

let get_by_id ((module C : Caqti_eio.CONNECTION)) ~id : t option =
  match C.find_opt get_by_id_req id with
  | Ok v -> Option.map of_row v
  | Error e -> raise_io ~id e

let get_by_path ((module C : Caqti_eio.CONNECTION)) ~path : t option =
  match C.find_opt get_by_path_req path with
  | Ok v -> Option.map of_row v
  | Error e -> raise_io ~id:path e

let all ((module C : Caqti_eio.CONNECTION)) : t list =
  match C.collect_list all_req () with
  | Ok rows -> List.map of_row rows
  | Error e -> raise_io ~id:"all" e

let delete_by_id ((module C : Caqti_eio.CONNECTION)) ~id : unit =
  match C.exec delete_by_id_req id with
  | Ok () -> ()
  | Error e -> raise_io ~id e

let clear_runtime_fields ((module C : Caqti_eio.CONNECTION)) ~id : unit =
  match C.exec clear_runtime_fields_req id with
  | Ok () -> ()
  | Error e -> raise_io ~id e

(* ---- Manifest persistence ------------------------------------------ *)

(* The in-memory representation round-trips with [Schema.manifest]
 * (= (string * string) list, unit_filename -> sha256). Replace is a
 * wipe-and-reinsert inside a single transaction, so a project's
 * manifest is atomically updated per-invocation. *)

let manifest_delete_req =
  (string ->. unit) "DELETE FROM manifest WHERE project_id = ?"

let manifest_insert_req =
  (t3 string string string ->. unit)
    "INSERT INTO manifest (project_id, unit_filename, sha256) \
     VALUES (?, ?, ?)"

let manifest_select_req =
  (string ->* t2 string string)
    "SELECT unit_filename, sha256 FROM manifest \
     WHERE project_id = ? ORDER BY unit_filename"

let replace_manifest ((module C : Caqti_eio.CONNECTION)) ~project_id
    ~(rows : Schema.manifest) : unit =
  match
    C.with_transaction (fun () ->
        match C.exec manifest_delete_req project_id with
        | Error e -> Error e
        | Ok () ->
            let rec loop = function
              | [] -> Ok ()
              | (unit_fn, sha256) :: tl -> (
                  match C.exec manifest_insert_req (project_id, unit_fn, sha256) with
                  | Ok () -> loop tl
                  | Error e -> Error e)
            in
            loop rows)
  with
  | Ok () -> ()
  | Error e -> raise_io ~id:project_id e

let load_manifest ((module C : Caqti_eio.CONNECTION)) ~project_id :
    Schema.manifest =
  match C.collect_list manifest_select_req project_id with
  | Ok rows -> rows
  | Error e -> raise_io ~id:project_id e

(* ---- Pure manifest diff (ported from pctl/lib/manifest.nu) --------- *)

open Schema

let diff_manifest ~(before : manifest) ~(after : manifest) : plan_row list =
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

let manifest_summary rows =
  Printf.sprintf "+%d ~%d =%d -%d"
    (count_by Added rows)
    (count_by Changed rows)
    (count_by Unchanged rows)
    (count_by Removed rows)
