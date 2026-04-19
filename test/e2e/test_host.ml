(* e2e parity for tests/e2e/host_test.nu + host_not_registered_test.nu. *)

let () =
  Harness.skip_or_run ~name:"test_host" @@ fun () ->
  (* Scenario 1: after `up`, `host` prints a valid 127.0.0.N. *)
  (Harness.with_scratch ~services:[ Harness.service "web" ]
   @@ fun scratch ->
   Harness.check_rc_zero ~label:"up" (Harness.up ~scratch);
   let rc, printed = Harness.host ~scratch in
   Harness.check_rc_zero ~label:"host" rc;
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
  Harness.assert_contains ~label:"stderr mentions 'not registered'" stderr_text
    "not registered";
  Printf.printf
    "test_host OK (scenario 2, unregistered rc=%d, stderr mentions 'not \
     registered')\n"
    rc
