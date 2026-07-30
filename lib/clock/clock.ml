(* Clock — wall-clock and boot-id source.
 *
 * Split out of the CLI layer so Pipeline can be tested with a frozen
 * clock for deterministic timestamps and manifest rows. *)

let boot_id_path = "/proc/sys/kernel/random/boot_id"

(* input_all, not in_channel_length: /proc reports length 0. Raises on a
 * blank read too — "" makes Session.reset and gc delete every row (pctl-2jn). *)
let read_boot_id_exn ?(path = boot_id_path) () : string =
  let raw = String.trim (In_channel.with_open_text path In_channel.input_all) in
  if raw = "" then raise (Sys_error (path ^ ": empty boot id")) else raw

module type S = sig
  val now_iso8601 : unit -> string
  val read_boot_id : unit -> string
end

module Real : S = struct
  let now_iso8601 () : string =
    let tm = Unix.gmtime (Unix.gettimeofday ()) in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d+00:00"
      (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
      tm.tm_hour tm.tm_min tm.tm_sec

  (* Degrades for [Pipeline]'s metadata stamp only, never for a decision
   * that removes rows. "" is unreachable there in practice — pctl-4qh. *)
  let read_boot_id () : string = try read_boot_id_exn () with _ -> ""
end

let frozen ~now ~boot : (module S) =
  (module struct
    let now_iso8601 () = now
    let read_boot_id () = boot
  end)
