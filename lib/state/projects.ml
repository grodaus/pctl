(* Projects — CRUD over the `projects` table.
 *
 * Row shape (migrations/001_init.sql):
 *   id           TEXT PRIMARY KEY
 *   path         TEXT NOT NULL
 *   host         TEXT
 *   started_at   TEXT
 *   store_tree   TEXT
 *   session_id   TEXT
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
