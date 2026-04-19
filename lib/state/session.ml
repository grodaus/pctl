(* Session — boot-scoped clearing of per-invocation project columns.
 *
 * pctl binds host / started_at / store_tree / session_id to a single
 * boot: after a reboot, the systemd --user instance is gone, so any
 * row still carrying a stale session_id is pointing at nothing. On
 * every invocation, [reset] clears those columns for rows whose
 * session_id does not match the current boot_id, then updates
 * meta.last_boot_id.
 *
 * Caller responsibility: invoke [reset conn] exactly once per pctl
 * invocation, BEFORE any other query on the connection. Opportunistic
 * GC, project lookup, upsert — all of it presupposes the session has
 * been reconciled. See docs/src/plans/20260419-ocaml-rewrite.md
 * ("SQLite schema (v1)" → "Session scoping on every invocation"). *)

let boot_id_path = "/proc/sys/kernel/random/boot_id"

(* /proc files report length 0 via [in_channel_length] (they are virtual
 * — the kernel can't know the rendered size without reading). We must
 * drain the channel by reading until EOF instead of pre-sizing by
 * [in_channel_length]. Pre-fix, [Session.reset] saw "" as the boot_id
 * and wiped every row on every invocation. *)
let read_boot_id () : string =
  let ic = open_in boot_id_path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let buf = Buffer.create 64 in
      (try
         while true do
           Buffer.add_channel buf ic 1
         done
       with End_of_file -> ());
      String.trim (Buffer.contents buf))

let reset_query =
  let open Caqti_request.Infix in
  let open Caqti_type.Std in
  (string ->. unit)
    "UPDATE projects \
     SET host = NULL, started_at = NULL, store_tree = NULL, session_id = NULL \
     WHERE session_id IS NOT NULL AND session_id != ?"

let raise_io ~id (e : [> Caqti_error.t ]) =
  raise
    (Schema.Pctl_error
       (Schema.Registry_io { id; reason = Caqti_error.show e }))

(* Private INSERT/UPSERT that returns Result instead of raising, so
 * [with_transaction] sees an `Error` for a failed meta update and
 * rolls back the projects UPDATE rather than relying on the
 * Fiber.cleanup exception path. The public [Db.meta_set] keeps its
 * raise-on-failure contract; this is only used inside the transaction. *)
let set_meta_q =
  let open Caqti_request.Infix in
  let open Caqti_type.Std in
  (t2 string string ->. unit)
    "INSERT INTO meta (key, value) VALUES (?, ?) \
     ON CONFLICT(key) DO UPDATE SET value = excluded.value"

let reset_with_boot_id (conn : Db.t) ~(boot_id : string) : unit =
  let (module C : Caqti_eio.CONNECTION) = conn in
  match
    C.with_transaction (fun () ->
        match C.exec reset_query boot_id with
        | Error e -> Error e
        | Ok () -> (
            match C.exec set_meta_q ("last_boot_id", boot_id) with
            | Error e -> Error e
            | Ok () -> Ok ()))
  with
  | Ok () -> ()
  | Error e -> raise_io ~id:"session_reset" e

let reset (conn : Db.t) : unit =
  let boot_id = read_boot_id () in
  reset_with_boot_id conn ~boot_id
