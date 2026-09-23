(* Projects — CRUD over the `projects` table, plus the `manifest` table.
 *
 * Project row shape (migrations/001_init.sql + 002_spec_blob.sql):
 *   id           TEXT PRIMARY KEY
 *   path         TEXT NOT NULL
 *   host         TEXT
 *   started_at   TEXT
 *   spec_file   TEXT
 *   session_id   TEXT
 *   spec_json    TEXT  -- full spec.json as persisted by the last `up`
 *
 * Manifest row shape (migrations/004_manifest_ownership.sql):
 *   project_id      TEXT
 *   unit_filename   TEXT
 *
 * A project's manifest is the set of unit filenames it owns — what down
 * and gc may delete. It holds no hashes: the diff's left side is read
 * from user.control, which does not outlive a reboot the way this table
 * does (pctl-468).
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
  spec_file : string option;
  session_id : string option;
  spec_json : string option;
}

let row_type =
  (* id, path, host, started_at, spec_file, session_id, spec_json *)
  t7 string string (option string) (option string) (option string)
    (option string) (option string)

let to_row r =
  ( r.id,
    r.path,
    r.host,
    r.started_at,
    r.spec_file,
    r.session_id,
    r.spec_json )

let of_row (id, path, host, started_at, spec_file, session_id, spec_json) =
  { id; path; host; started_at; spec_file; session_id; spec_json }

(* Upsert: INSERT OR on-conflict update. Keeps id/path stable; other
 * columns are overwritten (they are session-scoped and reset by
 * [Session.reset] at a different boot). *)
let upsert_req =
  (row_type ->. unit)
    "INSERT INTO projects \
       (id, path, host, started_at, spec_file, session_id, spec_json) \
     VALUES (?, ?, ?, ?, ?, ?, ?) \
     ON CONFLICT(id) DO UPDATE SET \
       path       = excluded.path, \
       host       = excluded.host, \
       started_at = excluded.started_at, \
       spec_file = excluded.spec_file, \
       session_id = excluded.session_id, \
       spec_json  = excluded.spec_json"

let get_by_id_req =
  (string ->? row_type)
    "SELECT id, path, host, started_at, spec_file, session_id, spec_json \
     FROM projects WHERE id = ?"

let all_req =
  (unit ->* row_type)
    "SELECT id, path, host, started_at, spec_file, session_id, spec_json \
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
     SET host = NULL, started_at = NULL, spec_file = NULL, session_id = NULL, \
         spec_json = NULL \
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

(* Replace is a wipe-and-reinsert inside a single transaction, so a
 * project's manifest is atomically updated. *)

let manifest_delete_req =
  (string ->. unit) "DELETE FROM manifest WHERE project_id = ?"

let manifest_insert_req =
  (t2 string string ->. unit)
    "INSERT INTO manifest (project_id, unit_filename) VALUES (?, ?)"

let manifest_select_req =
  (string ->* string)
    "SELECT unit_filename FROM manifest \
     WHERE project_id = ? ORDER BY unit_filename"

let replace_manifest ((module C : Caqti_eio.CONNECTION)) ~project_id
    ~(units : Schema.Unit_filename.t list) : unit =
  match
    C.with_transaction (fun () ->
        match C.exec manifest_delete_req project_id with
        | Error e -> Error e
        | Ok () ->
            let rec loop = function
              | [] -> Ok ()
              | uf :: tl -> (
                  let unit_fn = Schema.Unit_filename.to_string uf in
                  match C.exec manifest_insert_req (project_id, unit_fn) with
                  | Ok () -> loop tl
                  | Error e -> Error e)
            in
            loop (List.sort_uniq Schema.Unit_filename.compare units))
  with
  | Ok () -> ()
  | Error e -> raise_io ~id:project_id e

let load_manifest ((module C : Caqti_eio.CONNECTION)) ~project_id :
    Schema.Unit_filename.t list =
  match C.collect_list manifest_select_req project_id with
  | Ok rows -> List.map Schema.Unit_filename.of_string_exn rows
  | Error e -> raise_io ~id:project_id e
