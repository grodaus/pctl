(* Not in_channel_length + really_input_string: procfs files report a
 * length of 0 — see lib/clock/clock.ml. *)
let read_file path = In_channel.with_open_bin path In_channel.input_all

(* Stdlib has no substring search. *)
let contains haystack needle =
  needle = ""
  ||
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false
