(* Db — SQLite connection factory.
 *
 * Opens (or creates) the pctl state database and returns a caqti-eio
 * first-class Connection module. Every connection has
 * [PRAGMA foreign_keys = ON] asserted, which is per-connection in
 * SQLite (the default is OFF) — tests and production both go through
 * this entry point to keep FK behaviour consistent.
 *
 * Path resolution:
 *   $PCTL_STATE_DB      — explicit override (tests use this too)
 *   $XDG_STATE_HOME     — "$XDG_STATE_HOME/pctl/state.db"
 *   fallback            — "$HOME/.local/state/pctl/state.db"
 *
 * The URI scheme for sqlite3 is `sqlite3:<path>` (file on disk) or
 * `sqlite3::memory:` (in-memory — note the double colon). Tests use
 * the in-memory form via [connect_uri]; production uses [connect]. *)

module Caqti_request = Caqti_request
module Caqti_type = Caqti_type

let default_path () =
  match Sys.getenv_opt "PCTL_STATE_DB" with
  | Some p -> p
  | None ->
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

(* Enable foreign keys on every fresh connection. SQLite defaults to
 * OFF; the pragma is per-connection and not persisted. *)
let foreign_keys_on_req =
  let open Caqti_request.Infix in
  let open Caqti_type.Std in
  (unit ->. unit) "PRAGMA foreign_keys = ON"

let enable_foreign_keys (module C : Caqti_eio.CONNECTION) =
  match C.exec foreign_keys_on_req () with
  | Ok () -> ()
  | Error e ->
      raise
        (Schema.Pctl_error
           (Schema.Registry_io
              { id = "db"; reason = Caqti_error.show e }))

let connect_uri ~sw ~stdenv (uri : Uri.t) : t =
  match Caqti_eio_unix.connect ~sw ~stdenv uri with
  | Ok conn ->
      enable_foreign_keys conn;
      conn
  | Error e ->
      raise
        (Schema.Pctl_error
           (Schema.Registry_io
              { id = Uri.to_string uri; reason = Caqti_error.show e }))

let connect ~sw ~stdenv ?path () : t =
  let path = match path with Some p -> p | None -> default_path () in
  if path <> ":memory:" && not (String.equal path "") then
    ensure_parent_dir path;
  let uri =
    if path = ":memory:" then Uri.of_string "sqlite3::memory:"
    else Uri.of_string (Printf.sprintf "sqlite3:%s" path)
  in
  connect_uri ~sw ~stdenv uri
