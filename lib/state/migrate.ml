(* Migrate — SQLite schema migration runner.
 *
 * The migration SQL lives in the top-level `migrations/` directory and is
 * embedded at build time via [ppx_blob]. The dune stanza for this library
 * declares `(preprocessor_deps (file ../../migrations/001_init.sql))` so
 * the file is copied into the build directory and visible to ppx_blob.
 *
 * Only v1 exists today. Re-running [run] on an already-migrated database
 * is a no-op: the runner reads [meta.schema_version] and skips each
 * migration whose target version is <= the current.
 *
 * Each migration is applied inside a `with_transaction` so partial
 * application on failure is impossible. *)

let init_sql : string = [%blob "../../migrations/001_init.sql"]

(* A migration: version it bumps to and the SQL to run. Kept as a
 * simple list so adding a migration in a future phase is a one-line
 * append; no external catalog. *)
type migration = {
  target_version : int;
  sql : string;
}

let all : migration list = [ { target_version = 1; sql = init_sql } ]

(* `meta.schema_version` is a TEXT column (see 001_init.sql). Absent
 * means the schema hasn't been created yet — we're at version 0. *)
let current_version (conn : Db.t) : int =
  let exists_req =
    Caqti_request.Infix.(Caqti_type.Std.(unit ->? string))
      "SELECT name FROM sqlite_master WHERE type='table' AND name='meta'"
  in
  let (module C : Caqti_eio.CONNECTION) = conn in
  match C.find_opt exists_req () with
  | Error e ->
      raise
        (Schema.Pctl_error
           (Schema.Registry_io
              { id = "schema_version"; reason = Caqti_error.show e }))
  | Ok None -> 0
  | Ok (Some _) -> (
      match Meta.get conn ~key:"schema_version" with
      | None -> 0
      | Some s -> ( try int_of_string s with _ -> 0))

(* Run each SQL statement in a script (split on ';') as a single
 * query; Caqti's exec takes one statement, so we split naively. Each
 * non-empty, non-whitespace chunk is exec'd with oneshot=true since
 * the statement comes from a string. *)
let split_statements (sql : string) : string list =
  String.split_on_char ';' sql
  |> List.map String.trim
  |> List.filter (fun s -> String.length s > 0)

let exec_script (conn : Db.t) (sql : string) : unit =
  let (module C : Caqti_eio.CONNECTION) = conn in
  List.iter
    (fun stmt ->
      let req =
        Caqti_request.Infix.(Caqti_type.Std.(unit ->. unit))
          ~oneshot:true stmt
      in
      match C.exec req () with
      | Ok () -> ()
      | Error e ->
          raise
            (Schema.Pctl_error
               (Schema.Registry_io
                  { id = "migrate"; reason = Caqti_error.show e })))
    (split_statements sql)

let apply_one (conn : Db.t) (m : migration) : unit =
  let (module C : Caqti_eio.CONNECTION) = conn in
  match
    C.with_transaction (fun () ->
        exec_script conn m.sql;
        (* bump meta.schema_version — for v1 the INSERT in 001_init.sql
         * already sets '1', so this is idempotent for v1 but correct
         * for v2+ which will only run the DDL. *)
        Meta.set conn ~key:"schema_version"
          ~value:(string_of_int m.target_version);
        Ok ())
  with
  | Ok () -> ()
  | Error e ->
      raise
        (Schema.Pctl_error
           (Schema.Registry_io
              { id = Printf.sprintf "migrate:v%d" m.target_version;
                reason = Caqti_error.show e }))

let run (conn : Db.t) : unit =
  let cur = current_version conn in
  List.iter
    (fun m -> if m.target_version > cur then apply_one conn m)
    all
