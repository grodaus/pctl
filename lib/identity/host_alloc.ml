(* Host allocation — ported from the prior Nushell identity module.
 *
 *   first_byte  = first raw byte of MD5(id)
 *   initial     = first_byte mod 253 + 2     → range 2..254 inclusive
 *   walk        = bump ..254 then wrap to 2; stop at first slot not in taken
 *   exhaustion  = raise after 253 tries (every slot taken)
 *
 * MD5 is used only as a seed — inherited from the prior Nushell implementation
 * for byte-compat with existing allocations; not a cryptographic choice. *)

open Schema

let md5_first_byte s =
  let d = Digestif.MD5.(digest_string s |> to_raw_string) in
  Char.code d.[0]

let host_for n = Printf.sprintf "127.0.0.%d" n

let allocate ~(id : project_id) ~(taken : host list) : host =
  let id_s = Project_id.to_string id in
  let taken_set = List.map Host.to_string taken in
  let first_byte = md5_first_byte id_s in
  let initial = (first_byte mod 253) + 2 in
  let rec loop n tries =
    if tries >= 253 then
      raise
        (Pctl_error
           (Identity_invalid
              {
                path = id_s;
                reason =
                  Printf.sprintf
                    "allocate-host: no free slot in 127.0.0.2..254 for id '%s'"
                    id_s;
              }))
    else
      let candidate = host_for n in
      if not (List.mem candidate taken_set) then Host.of_string_exn candidate
      else
        let next = if n < 254 then n + 1 else 2 in
        loop next (tries + 1)
  in
  loop initial 0
