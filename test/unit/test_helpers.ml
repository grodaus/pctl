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
  needle = ""
  ||
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

(* Write a string to a fresh temp file; return its path. Tests that need
 * hand-crafted malformed input (the good-path fixtures come from
 * nix build) use this to exercise specific error paths. *)
let write_temp_file ~prefix ~contents =
  let path = Filename.temp_file prefix ".json" in
  let oc = open_out path in
  output_string oc contents;
  close_out oc;
  path

(* Environment variable helpers.
 *
 * OCaml 5.4's [Unix] module (as built in this nixpkgs) does NOT expose
 * [Unix.unsetenv]: [Unix.putenv "HOME" ""] leaves [Sys.getenv_opt "HOME"]
 * returning [Some ""], which is not the "unset" path we need to exercise
 * in tests. Fall back to libc's C [unsetenv] via ctypes-foreign. *)

let c_unsetenv =
  Foreign.foreign "unsetenv" Ctypes.(string @-> returning int)

let unsetenv name = ignore (c_unsetenv name)

(* Save, mutate, restore an environment variable around [f]. If the var
 * was unset before the call, it is re-unset afterwards. *)
let with_env ~name ~value f =
  let saved = Sys.getenv_opt name in
  (match value with
   | Some v -> Unix.putenv name v
   | None -> unsetenv name);
  Fun.protect
    ~finally:(fun () ->
      match saved with
      | Some v -> Unix.putenv name v
      | None -> unsetenv name)
    f

(* Run [f] in a fresh tmpdir (chdir into it, cleanup + restore cwd on
 * exit). Uses a small recursive rmdir to clean up without spawning a
 * shell. *)
let rec rm_rf path =
  match (Unix.lstat path).st_kind with
  | Unix.S_DIR ->
      let dh = Unix.opendir path in
      Fun.protect
        ~finally:(fun () -> Unix.closedir dh)
        (fun () ->
          try
            while true do
              match Unix.readdir dh with
              | "." | ".." -> ()
              | entry -> rm_rf (Filename.concat path entry)
            done
          with End_of_file -> ());
      Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let with_tmpdir f =
  let prev = Sys.getcwd () in
  let dir = Filename.temp_file "pctl-test-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.chdir prev with _ -> ());
      (try rm_rf dir with _ -> ()))
    (fun () ->
      Sys.chdir dir;
      (* macOS has /private/tmp → /tmp symlink shenanigans; resolve to
       * whatever getcwd reports so tests can compare strings cleanly. *)
      f (Sys.getcwd ()))
