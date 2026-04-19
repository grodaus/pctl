(* Db — SQLite connection, meta table, and schema migrations.
 *
 * Opens (or creates) the pctl state database and returns a caqti-eio
 * first-class Connection module. Every connection has
 * [PRAGMA foreign_keys = ON] asserted, which is per-connection in
 * SQLite (the default is OFF) — tests and production both go through
 * this entry point to keep FK behaviour consistent.
 *
 * Path resolution:
 *   $XDG_STATE_HOME     — "$XDG_STATE_HOME/pctl/state.db"
 *   fallback            — "$HOME/.local/state/pctl/state.db"
 *
 * The URI scheme for sqlite3 is `sqlite3:<path>` (file on disk) or
 * `sqlite3::memory:` (in-memory — note the double colon). Tests use
 * the in-memory form via [connect_uri]; production uses [connect].
 *
 * The [meta] table (see migrations/001_init.sql) is a tiny KV for
 * single-row flags (schema_version, last_boot_id). Migrations are
 * embedded via [ppx_blob] and applied transactionally; re-running
 * [migrate] on an already-migrated database is a no-op. *)

module Caqti_request = Caqti_request
module Caqti_type = Caqti_type

(* ---- Connection ---------------------------------------------------- *)

let default_path () =
  let base =
    match Sys.getenv_opt "XDG_STATE_HOME" with
    | Some d when String.length d > 0 -> d
    | _ ->
        let home =
          match Sys.getenv_opt "HOME" with
          | Some h when String.length h > 0 -> h
          | _ -> "/"
        in
        Filename.concat home ".local/state"
  in
  Filename.concat (Filename.concat base "pctl") "state.db"

let ensure_parent_dir path =
  let dir = Filename.dirname path in
  let rec mkdir_p d =
    if d = "/" || d = "." || d = "" then ()
    else if Sys.file_exists d && Sys.is_directory d then ()
    else begin
      mkdir_p (Filename.dirname d);
      try Unix.mkdir d 0o700
      with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    end
  in
  mkdir_p dir

(* Caqti connection as a first-class module. *)
type t = (module Caqti_eio.CONNECTION)

let raise_io ~id (e : [> Caqti_error.t ]) =
  raise
    (Schema.Pctl_error
       (Schema.Registry_io { id; reason = Caqti_error.show e }))

(* Enable foreign keys on every fresh connection. SQLite defaults to
 * OFF; the pragma is per-connection and not persisted. *)
let foreign_keys_on_req =
  let open Caqti_request.Infix in
  let open Caqti_type.Std in
  (unit ->. unit) "PRAGMA foreign_keys = ON"

let enable_foreign_keys (module C : Caqti_eio.CONNECTION) =
  match C.exec foreign_keys_on_req () with
  | Ok () -> ()
  | Error e -> raise_io ~id:"db" e

let connect_uri ~sw ~stdenv (uri : Uri.t) : t =
  match Caqti_eio_unix.connect ~sw ~stdenv uri with
  | Ok conn ->
      enable_foreign_keys conn;
      conn
  | Error e -> raise_io ~id:(Uri.to_string uri) e

let connect ~sw ~stdenv ?path () : t =
  let path = match path with Some p -> p | None -> default_path () in
  if path <> ":memory:" && not (String.equal path "") then
    ensure_parent_dir path;
  let uri =
    if path = ":memory:" then Uri.of_string "sqlite3::memory:"
    else Uri.of_string (Printf.sprintf "sqlite3:%s" path)
  in
  connect_uri ~sw ~stdenv uri

(* ---- Meta table (key/value singletons) ----------------------------- *)

let meta_get_req =
  let open Caqti_request.Infix in
  let open Caqti_type.Std in
  (string ->? string) "SELECT value FROM meta WHERE key = ?"

let meta_set_req =
  let open Caqti_request.Infix in
  let open Caqti_type.Std in
  (t2 string string ->. unit)
    "INSERT INTO meta (key, value) VALUES (?, ?) \
     ON CONFLICT(key) DO UPDATE SET value = excluded.value"

let meta_get ((module C : Caqti_eio.CONNECTION)) ~key : string option =
  match C.find_opt meta_get_req key with
  | Ok v -> v
  | Error e -> raise_io ~id:key e

let meta_set ((module C : Caqti_eio.CONNECTION)) ~key ~value : unit =
  match C.exec meta_set_req (key, value) with
  | Ok () -> ()
  | Error e -> raise_io ~id:key e

(* ---- Schema migrations --------------------------------------------- *)

let init_sql : string = [%blob "../../migrations/001_init.sql"]
let spec_blob_sql : string = [%blob "../../migrations/002_spec_blob.sql"]

(* A migration: version it bumps to and the SQL to run. Kept as a
 * simple list so adding a migration in a future phase is a one-line
 * append; no external catalog. *)
type migration = { target_version : int; sql : string }

let migrations : migration list =
  [
    { target_version = 1; sql = init_sql };
    { target_version = 2; sql = spec_blob_sql };
  ]

(* [meta.schema_version] is a TEXT column (see 001_init.sql). Absent
 * means the schema hasn't been created yet — we're at version 0. *)
let current_version (conn : t) : int =
  let exists_req =
    let open Caqti_request.Infix in
    let open Caqti_type.Std in
    (unit ->? string)
      "SELECT name FROM sqlite_master WHERE type='table' AND name='meta'"
  in
  let (module C : Caqti_eio.CONNECTION) = conn in
  match C.find_opt exists_req () with
  | Error e -> raise_io ~id:"schema_version" e
  | Ok None -> 0
  | Ok (Some _) -> (
      match meta_get conn ~key:"schema_version" with
      | None -> 0
      | Some s -> (
          match int_of_string_opt s with
          | Some v -> v
          | None ->
              raise
                (Schema.Pctl_error
                   (Schema.Registry_io
                      {
                        id = "schema_version";
                        reason =
                          Printf.sprintf
                            "meta.schema_version is not an integer: %S" s;
                      }))))

(* Split a multi-statement SQL script on `;`. Caqti's exec runs one
 * statement per call; the statements come from a trusted embedded
 * string, so a naive split is fine. *)
let split_statements (sql : string) : string list =
  String.split_on_char ';' sql
  |> List.map String.trim
  |> List.filter (fun s -> String.length s > 0)

let exec_script (conn : t) (sql : string) : unit =
  let (module C : Caqti_eio.CONNECTION) = conn in
  List.iter
    (fun stmt ->
      let req =
        let open Caqti_request.Infix in
        let open Caqti_type.Std in
        (unit ->. unit) ~oneshot:true stmt
      in
      match C.exec req () with
      | Ok () -> ()
      | Error e -> raise_io ~id:"migrate" e)
    (split_statements sql)

let apply_migration (conn : t) (m : migration) : unit =
  let (module C : Caqti_eio.CONNECTION) = conn in
  match
    C.with_transaction (fun () ->
        exec_script conn m.sql;
        (* Bump meta.schema_version. For v1 the INSERT in 001_init.sql
         * already sets '1', so this is idempotent for v1 but correct
         * for v2+ which will only run the DDL. *)
        meta_set conn ~key:"schema_version"
          ~value:(string_of_int m.target_version);
        Ok ())
  with
  | Ok () -> ()
  | Error e -> raise_io ~id:(Printf.sprintf "migrate:v%d" m.target_version) e

let migrate (conn : t) : unit =
  let cur = current_version conn in
  List.iter
    (fun m -> if m.target_version > cur then apply_migration conn m)
    migrations
