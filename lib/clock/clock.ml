(* Clock — wall-clock and boot-id source.
 *
 * Split out of lib/cli/common.ml so Pipeline can be tested with a
 * frozen clock for deterministic timestamps and manifest rows. *)

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

  (* Drain /proc/sys/kernel/random/boot_id by reading to EOF — virtual
   * files report length 0 via in_channel_length. Same policy as
   * lib/state/session.ml. Returns "" on any failure (caller stores NULL
   * when empty). *)
  let read_boot_id () : string =
    try
      let ic = open_in "/proc/sys/kernel/random/boot_id" in
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
    with _ -> ""
end

let frozen ~now ~boot : (module S) =
  (module struct
    let now_iso8601 () = now
    let read_boot_id () = boot
  end)
