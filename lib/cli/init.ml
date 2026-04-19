(* Init — `pctl init [--force]`.
 *
 * Oracle: the prior Nushell `init` command + templates/init/{flake.nix,.gitignore}.
 * Nushell behaviour ported 1:1:
 *   - If flake.nix exists in cwd AND --force is not set, refuse with
 *     exit 2 and a stderr message.
 *   - Else copy templates/init/flake.nix to cwd/flake.nix.
 *   - .gitignore: if one exists in cwd, append only the template lines
 *     that aren't already present (merge, not overwrite); if none, copy
 *     the template verbatim.
 *   - Print two stdout lines: "pctl init: wrote <flake>" and
 *     "pctl init: updated <gitignore>".
 *
 * Template location: compile-time, using [Sys.getenv_opt "PCTL_TEMPLATES_DIR"]
 * with a fallback to "../share/pctl/templates/init" relative to the binary.
 * In Nix builds the binary is under /nix/store/.../bin/pctl and templates
 * live alongside it via a postInstall mv; in a dev tree the env var
 * points at ./templates/init. We read the env var first (explicit >
 * implicit) and fall back to the binary-relative path.
 *
 * Exit codes: 2 for "refuse to overwrite", 0 otherwise. *)

let read_file (path : string) : string =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () ->
      let n = in_channel_length ic in
      really_input_string ic n)

let write_file (path : string) (contents : string) : unit =
  let oc = open_out path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

(* Locate the templates/init directory:
 *   1. PCTL_TEMPLATES_DIR env var (overrides all; used in tests).
 *   2. <binary-dir>/../share/pctl/templates/init (nix install layout).
 *   3. <cwd>/templates/init (dev tree fallback).
 * Raise Pctl_error if none exist. *)
let templates_dir () : string =
  let bin_dir = Filename.dirname Sys.executable_name in
  let nix_layout =
    List.fold_left Filename.concat bin_dir
      [ ".."; "share"; "pctl"; "templates"; "init" ]
  in
  let dev_layout =
    List.fold_left Filename.concat (Sys.getcwd ()) [ "templates"; "init" ]
  in
  let candidates =
    match Sys.getenv_opt "PCTL_TEMPLATES_DIR" with
    | Some e -> [ e; nix_layout; dev_layout ]
    | None -> [ nix_layout; dev_layout ]
  in
  match
    List.find_opt
      (fun p -> Sys.file_exists (Filename.concat p "flake.nix"))
      candidates
  with
  | Some p -> p
  | None ->
      raise
        (Schema.Pctl_error
           (Schema.Install_failed
              {
                path = "templates/init";
                reason =
                  "pctl init: cannot find templates/init directory — set \
                   PCTL_TEMPLATES_DIR or run from the pctl source tree";
              }))

(* Split on '\n' but drop a trailing empty segment when the input ended
 * with a newline (so "a\nb\n" yields ["a"; "b"], not ["a"; "b"; ""]). *)
let split_lines s =
  match List.rev (String.split_on_char '\n' s) with
  | "" :: rest -> List.rev rest
  | parts -> List.rev parts

let run ?(force = false) () : int =
  Common.run_with_errors (fun () ->
      let cwd = Sys.getcwd () in
      let target_flake = Filename.concat cwd "flake.nix" in
      let target_gitignore = Filename.concat cwd ".gitignore" in
      if Sys.file_exists target_flake && not force then
        raise
          (Schema.Pctl_error
             (Schema.Install_failed
                {
                  path = target_flake;
                  reason =
                    Printf.sprintf
                      "pctl init: flake.nix already exists at %s — pass \
                       --force to overwrite"
                      target_flake;
                }));
      let td = templates_dir () in
      let src_flake = Filename.concat td "flake.nix" in
      let src_gitignore = Filename.concat td ".gitignore" in
      (* Copy flake.nix *)
      let flake_body = read_file src_flake in
      write_file target_flake flake_body;
      (* Merge .gitignore if template exists. *)
      if Sys.file_exists src_gitignore then begin
        let template_body = read_file src_gitignore in
        if Sys.file_exists target_gitignore then begin
          let existing = read_file target_gitignore in
          let existing_lines = split_lines existing in
          let template_lines = split_lines template_body in
          let needed =
            List.filter (fun l -> not (List.mem l existing_lines)) template_lines
          in
          if needed <> [] then begin
            let trailing_nl =
              if String.length existing > 0
                 && existing.[String.length existing - 1] = '\n'
              then ""
              else "\n"
            in
            let addition = trailing_nl ^ String.concat "\n" needed ^ "\n" in
            let oc =
              open_out_gen [ Open_wronly; Open_append ] 0o644 target_gitignore
            in
            Fun.protect
              ~finally:(fun () -> close_out oc)
              (fun () -> output_string oc addition)
          end
        end
        else write_file target_gitignore template_body
      end;
      Printf.printf "pctl init: wrote %s\n" target_flake;
      Printf.printf "pctl init: updated %s\n" target_gitignore)
