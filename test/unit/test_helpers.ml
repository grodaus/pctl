(* Shared utilities for the pure-core unit tests.
 *
 * Fixtures live under test/unit/fixtures/; dune's [(deps (source_tree fixtures))]
 * copies them into each test's build dir. Tests run with cwd = that dir, so
 * a relative path under fixtures/ works. *)

let read_file p =
  let ic = open_in p in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let render_fixture_dir = "fixtures/render"
let render_fixture p = Filename.concat render_fixture_dir p
let spec_fixture name = Filename.concat "fixtures/spec" (name ^ ".json")

(* Substring predicate — alcotest lacks string-contains. Used by the
 * spec-loader tests to verify the offending field name appears in the
 * error text. *)
let contains_substring haystack needle =
  let hl = String.length haystack in
  let nl = String.length needle in
  if nl = 0 then true
  else if nl > hl then false
  else
    let rec loop i =
      if i > hl - nl then false
      else if String.sub haystack i nl = needle then true
      else loop (i + 1)
    in
    loop 0

(* Write a string to a fresh temp file; return its path. Tests that need
 * hand-crafted malformed input (the good-path fixtures come from
 * nix build) use this to exercise specific error paths. *)
let write_temp_file ~prefix ~contents =
  let path = Filename.temp_file prefix ".json" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  path
