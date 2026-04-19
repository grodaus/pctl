(* Tuor wire-format parity: pipe `pctl results --json` through `nu` using
 * the same transformations tuor/scripts/collect-pctl-artifacts.nu
 * performs, assert zero errors.
 *
 * This test depends on `nu` being on $PATH. If it isn't we print SKIP
 * and exit 0 — parity can only be tested on dev hosts. *)

let bash = "/run/current-system/sw/bin/bash"
let true_bin = "/run/current-system/sw/bin/true"

(* Find `nu` in PATH (Nushell sets NUSHELL_BIN in some environments). *)
let find_nu () : string option =
  match Sys.getenv_opt "NUSHELL" with
  | Some p when p <> "" && Sys.file_exists p -> Some p
  | _ ->
      let path =
        try Sys.getenv "PATH" with Not_found -> ""
      in
      let parts = String.split_on_char ':' path in
      List.find_map
        (fun d ->
          let candidate = Filename.concat d "nu" in
          if Sys.file_exists candidate then Some candidate else None)
        parts

let oneshot name exec_line =
  {
    Harness.name;
    probe = None;
    service_config =
      [
        ("Type", "oneshot");
        ("RemainAfterExit", "yes");
        ("ExecStart", exec_line);
        ("Slice", "pctl-@@PROJECT@@.slice");
      ];
    workspace = None;
  }

let simple name exec_line =
  {
    Harness.name;
    probe = None;
    service_config =
      [
        ("Type", "simple");
        ("ExecStart", exec_line);
        ("Slice", "pctl-@@PROJECT@@.slice");
      ];
    workspace = None;
  }

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_results_tuor_parity — %s\n" why;
      exit 0
  | None -> (
      match find_nu () with
      | None ->
          Printf.printf
            "SKIP: test_results_tuor_parity — nu not on PATH\n";
          exit 0
      | Some nu_bin ->
          (* Realistic two-service project: one oneshot-success, one
           * simple-long-running. Matches the minimum input shape that
           * tuor's collect script cares about. *)
          Harness.with_scratch
            ~services:
              [
                oneshot "pg" true_bin;
                simple "server"
                  (Printf.sprintf
                     "%s -c 'exec %s -c \"while true; do sleep 3600; \
                      done\"'"
                     bash bash);
              ]
          @@ fun scratch ->
          let rc = Harness.up_no_block ~scratch in
          if rc <> 0 then Alcotest.failf "up --no-block exit=%d" rc;
          let rc_j, out_j = Harness.results ~scratch ~timeout:15 ~json:true () in
          if rc_j <> 0 then
            Alcotest.failf "results --json exit=%d, stdout=%s" rc_j out_j;
          let trimmed = String.trim out_j in
          (* tuor's script calls `$r.stdout | from json`, then per row
           * `$"($r | get elapsed)ns" | into duration` and accesses
           * .name, .state, .kind. Emulate by writing the JSON to a tmp
           * file and having nu `open --raw` + `from json` it. *)
          let json_tmp = Filename.temp_file "pctl-tuor-parity" ".json" in
          let oc = open_out json_tmp in
          output_string oc trimmed;
          close_out oc;
          let nu_script =
            Printf.sprintf
              "let items = (open --raw %s | from json);\n\
               if ($items | length) == 0 { error make { msg: 'empty' } };\n\
               let rows = ($items | each {|r|\n\
               \  let dur = $\"($r | get elapsed)ns\" | into duration;\n\
               \  { name: ($r | get name), state: ($r | get state), kind: \
               ($r | get kind), duration: $dur }\n\
               });\n\
               for r in $rows { if ($r.name | is-empty) { error make { \
               msg: 'missing name' } } };\n\
               print ($rows | length)"
              (Filename.quote json_tmp)
          in
          let cmd =
            Printf.sprintf "%s -c %s" (Filename.quote nu_bin)
              (Filename.quote nu_script)
          in
          let ic = Unix.open_process_in cmd in
          let buf = Buffer.create 64 in
          (try
             while true do
               Buffer.add_channel buf ic 1
             done
           with End_of_file -> ());
          let status = Unix.close_process_in ic in
          (match status with
           | Unix.WEXITED 0 -> ()
           | Unix.WEXITED n ->
               (try Sys.remove json_tmp with _ -> ());
               Alcotest.failf
                 "nu-script parse rejected pctl JSON (exit=%d); input=%s"
                 n trimmed
           | _ ->
               (try Sys.remove json_tmp with _ -> ());
               Alcotest.failf "nu-script did not exit cleanly");
          (try Sys.remove json_tmp with _ -> ());
          Printf.printf "test_results_tuor_parity OK — nu parsed: %s\n"
            (String.trim (Buffer.contents buf)))
