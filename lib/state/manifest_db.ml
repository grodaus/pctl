(* Manifest_db — CRUD over the `manifest` table (project_id, unit_filename, sha256).
 *
 * The in-memory representation round-trips with [Schema.manifest]
 * (= (string * string) list, unit_filename -> sha256). Replace is a
 * wipe-and-reinsert inside a single transaction, so a project's
 * manifest is atomically updated per-invocation. *)

open Caqti_request.Infix
open Caqti_type.Std

let delete_all_req =
  (string ->. unit)
    "DELETE FROM manifest WHERE project_id = ?"

let insert_req =
  (t3 string string string ->. unit)
    "INSERT INTO manifest (project_id, unit_filename, sha256) \
     VALUES (?, ?, ?)"

let select_req =
  (string ->* t2 string string)
    "SELECT unit_filename, sha256 FROM manifest \
     WHERE project_id = ? ORDER BY unit_filename"

let raise_io ~id (e : [> Caqti_error.t ]) =
  raise
    (Schema.Pctl_error
       (Schema.Registry_io { id; reason = Caqti_error.show e }))

let replace_project_manifest ((module C : Caqti_eio.CONNECTION))
    ~project_id ~(rows : Schema.manifest) : unit =
  match
    C.with_transaction (fun () ->
        let open Result in
        match C.exec delete_all_req project_id with
        | Error e -> Error e
        | Ok () ->
            let rec loop = function
              | [] -> Ok ()
              | (unit_fn, sha256) :: tl -> (
                  match C.exec insert_req (project_id, unit_fn, sha256) with
                  | Ok () -> loop tl
                  | Error e -> Error e)
            in
            loop rows
            |> (function Ok () -> Ok () | Error e -> Error e))
  with
  | Ok () -> ()
  | Error e -> raise_io ~id:project_id e

let load_manifest ((module C : Caqti_eio.CONNECTION)) ~project_id :
    Schema.manifest =
  match C.collect_list select_req project_id with
  | Ok rows -> rows
  | Error e -> raise_io ~id:project_id e
