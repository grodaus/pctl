(* Project identity: derive a stable id from an absolute path, allocate
 * a 127.0.0.N host for it. Path expansion (tilde/env/normalize) lives
 * in [Schema.Project_path.of_raw]; [derive] takes the typed result. *)

open Schema

(* Lowercase raw basename, fold every run of non-[a-z0-9_] characters
 * into a single underscore, trim leading/trailing underscores. Empty
 * result falls back to "project" so the final id is never "_<hash>". *)
let non_id_chars_re =
  Re.compile (Re.rep1 (Re.compl [ Re.alnum; Re.char '_' ]))

let edge_underscores_re =
  Re.compile
    (Re.alt
       [ Re.seq [ Re.bos; Re.rep (Re.char '_') ]
       ; Re.seq [ Re.rep (Re.char '_'); Re.eos ] ])

let sanitize_basename raw =
  let lowered = String.lowercase_ascii raw in
  let folded = Re.replace_string non_id_chars_re ~by:"_" lowered in
  let trimmed = Re.replace_string edge_underscores_re ~by:"" folded in
  if trimmed = "" then "project" else trimmed

(* hash8 — first 8 hex chars of SHA-256 over the absolute path. *)

let sha256_hex s = Digestif.SHA256.(digest_string s |> to_hex)
let hash8 abs_path = String.sub (sha256_hex abs_path) 0 8

let derive ~(path : project_path) =
  let abs = Project_path.to_string path in
  let base = sanitize_basename (Filename.basename abs) in
  Project_id.of_string_exn (base ^ "_" ^ hash8 abs)

(* Host allocator.
 *
 *   first_byte  = first raw byte of MD5(id)
 *   initial     = first_byte mod 253 + 2     → range 2..254
 *   walk        = bump ..254 then wrap to 2; stop at first free slot
 *   exhaustion  = raise after 253 tries
 *
 * MD5 is a seed, not a cryptographic choice. *)

module Host_alloc = struct
  module Host_set = Set.Make (String)

  let md5_first_byte s =
    let d = Digestif.MD5.(digest_string s |> to_raw_string) in
    Char.code d.[0]

  let host_for n = Printf.sprintf "127.0.0.%d" n

  let allocate ~(id : project_id) ~(taken : host list) : host =
    let id_s = Project_id.to_string id in
    let taken_set =
      List.fold_left
        (fun s h -> Host_set.add (Host.to_string h) s)
        Host_set.empty taken
    in
    let initial = (md5_first_byte id_s mod 253) + 2 in
    let rec loop n tries =
      if tries >= 253 then
        raise
          (Pctl_error
             (Identity_invalid
                {
                  path = id_s;
                  reason =
                    Printf.sprintf
                      "Host.allocate: no free slot in 127.0.0.2..254 for id \
                       '%s'"
                      id_s;
                }))
      else
        let candidate = host_for n in
        if not (Host_set.mem candidate taken_set) then
          Host.of_string_exn candidate
        else loop (if n < 254 then n + 1 else 2) (tries + 1)
    in
    loop initial 0
end
