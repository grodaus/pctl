(* Meta — get/set of [meta] table rows.
 *
 * The meta table is `(key TEXT PRIMARY KEY, value TEXT NOT NULL)`; it
 * stores the schema version, last observed boot_id, and any future
 * single-row flags. Used by [Migrate] (schema_version) and [Session]
 * (last_boot_id). *)

open Caqti_request.Infix
open Caqti_type.Std

let get_req =
  (string ->? string)
    "SELECT value FROM meta WHERE key = ?"

let set_req =
  (t2 string string ->. unit)
    "INSERT INTO meta (key, value) VALUES (?, ?) \
     ON CONFLICT(key) DO UPDATE SET value = excluded.value"

let get ((module C : Caqti_eio.CONNECTION)) ~key : string option =
  match C.find_opt get_req key with
  | Ok v -> v
  | Error e ->
      raise
        (Schema.Pctl_error
           (Schema.Registry_io
              { id = key; reason = Caqti_error.show e }))

let set ((module C : Caqti_eio.CONNECTION)) ~key ~value : unit =
  match C.exec set_req (key, value) with
  | Ok () -> ()
  | Error e ->
      raise
        (Schema.Pctl_error
           (Schema.Registry_io
              { id = key; reason = Caqti_error.show e }))
