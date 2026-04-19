(* e2e parity for tests/e2e/host_test.nu + host_not_registered_test.nu. *)

let () =
  match Harness.skip_reason () with
  | Some why ->
      Printf.printf "SKIP: test_host — %s\n" why;
      exit 0
  | None ->
      (* Scenario 1: after `up`, `host` prints a valid 127.0.0.N. *)
      (Harness.with_scratch ~services:[ Harness.service "web" ]
       @@ fun scratch ->
       let rc = Harness.up ~scratch in
       if rc <> 0 then Alcotest.failf "up exit=%d" rc;
       let rc, printed = Harness.host ~scratch in
       if rc <> 0 then Alcotest.failf "host exit=%d, stdout=%s" rc printed;
       let trimmed = String.trim printed in
       let re = Str.regexp "^127\\.0\\.0\\.\\([0-9]+\\)$" in
       if not (Str.string_match re trimmed 0) then
         Alcotest.failf "host '%s' is not a 127.0.0.N" trimmed;
       Printf.printf "test_host OK — printed %s\n" trimmed);
      (* Scenario 2: host on unregistered project exits non-zero with
       * "not registered" on stderr. *)
      Harness.with_scratch ~services:[ Harness.service "web" ]
      @@ fun scratch ->
      let tmp = Filename.temp_file "pctl-e2e-stderr" ".log" in
      let fd = Unix.openfile tmp [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let saved = Unix.dup Unix.stderr in
      Unix.dup2 fd Unix.stderr;
      Unix.close fd;
      let rc, stdout = Harness.host ~scratch in
      flush Stdlib.stderr;
      Unix.dup2 saved Unix.stderr;
      Unix.close saved;
      let stderr_text =
        let ic = open_in tmp in
        let n = in_channel_length ic in
        let s = really_input_string ic n in
        close_in ic;
        (try Sys.remove tmp with _ -> ());
        s
      in
      if rc = 0 then
        Alcotest.failf "host on unregistered project exit=0, stdout=%s" stdout;
      let contains h n =
        let hl = String.length h and nl = String.length n in
        let rec go i =
          if i + nl > hl then false
          else if String.sub h i nl = n then true
          else go (i + 1)
        in
        nl = 0 || go 0
      in
      if not (contains stderr_text "not registered") then
        Alcotest.failf "error should mention 'not registered', got: %s"
          stderr_text;
      Printf.printf
        "test_host OK (scenario 2, unregistered rc=%d, stderr mentions 'not \
         registered')\n"
        rc
